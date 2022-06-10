Red/System [
	Title:	"low-level TCP port"
	Author: "Xie Qingtian"
	File: 	%tcp.reds
	Tabs: 	4
	Rights: "Copyright (C) 2015-2018 Red Foundation. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/red/red/blob/master/BSL-License.txt
	}
]

tcp-device: context [
	verbose: 1

	event-handler: func [
		data		[iocp-data!]
		/local
			p		[red-object!]
			msg		[red-object!]
			tcp		[sockdata!]
			type	[integer!]
			bin		[red-binary!]
			s		[series!]
			saddr	[sockaddr_in!]
			num		[integer!]
	][
		tcp: as sockdata! data
		p: as red-object! :tcp/port
		msg: p
		type: data/event

		switch type [
			IO_EVT_READ	[
				bin: as red-binary! (object/get-values p) + port/field-data
				s: GET_BUFFER(bin)
				s/tail: as cell! (as byte-ptr! s/offset) + data/transferred
				io/unpin-memory bin/node
				#if OS = 'Windows [
					either data/accept-sock = PENDING_IO_FLAG [
						free as byte-ptr! data
					][
						data/event: IO_EVT_NONE
					]
				]
				if zero? data/transferred [type: IO_EVT_CLOSE]
			]
			IO_EVT_WRITE	[
				io/unpin-memory tcp/send-buf
				#if OS = 'Windows [
					either data/accept-sock = PENDING_IO_FLAG [
						free as byte-ptr! data
					][
						data/event: IO_EVT_NONE
					]
				]
			]
			IO_EVT_ACCEPT	[
				iocp/bind g-iocp as int-ptr! data/accept-sock
				#either OS = 'Windows [
					msg: create-red-port p data/accept-sock
				][
					msg: create-red-port p socket/accept as-integer tcp/device :tcp/addr :tcp/addr-sz
				]
				io/fill-client-info msg tcp
				#if OS = 'Windows [
					socket/acceptex as-integer tcp/device :tcp/addr :tcp/addr-sz data
				]
			]
			IO_EVT_LOOKUP [
				saddr: as sockaddr_in! :tcp/addr
				num: htons tcp/accept-sock	;-- port number saved in accept-sock
				saddr/sin_family: num << 16 or AF_INET
				saddr/sa_data1: 0
				saddr/sa_data2: 0
				io/close-port p
				tcp-client p saddr size? sockaddr_in! AF_INET
				exit
			]
			default [data/event: IO_EVT_NONE]
		]

		io/call-awake p msg type
		if type = IO_EVT_CLOSE [close p]
	]

	create-red-port: func [
		proto		[red-object!]
		sock		[integer!]
		return:		[red-object!]
	][
		proto: io/make-port proto
		create-tcp-data proto sock
		proto
	]

	create-tcp-data: func [
		port	[red-object!]
		sock	[integer!]
		return: [iocp-data!]
	][
		as iocp-data! io/create-socket-data port sock as int-ptr! :event-handler size? sockdata!
	]

	get-tcp-data: func [
		red-port	[red-object!]
		return:		[sockdata!]
		/local
			state	[red-handle!]
			data	[iocp-data!]
			new		[sockdata!]
	][
		state: as red-handle! (object/get-values red-port) + port/field-state
		if TYPE_OF(state) <> TYPE_HANDLE [
			probe "ERROR: No low-level handle"
			0 ;; TBD throw error
		]

		#either OS = 'Windows [
			data: as iocp-data! state/value
			either data/event = IO_EVT_NONE [		;-- we can reuse this one
				as sockdata! data
			][										;-- needs to create a new one
				new: as sockdata! zero-alloc size? sockdata!
				new/event-handler: as iocp-event-handler! :event-handler
				new/device: data/device
				new/accept-sock: PENDING_IO_FLAG ;-- use it as a flag to indicate pending data
				copy-cell as cell! red-port as cell! :new/port
				new
			]
		][
			as sockdata! state/value
		]
	]

	tcp-client: func [
		port	[red-object!]
		saddr	[sockaddr_in!]
		addr-sz	[integer!]
		type	[integer!]
		/local
			fd	[integer!]
	][
		#if debug? = yes [if verbose > 0 [io/debug "tcp client"]]

		fd: socket/create type SOCK_STREAM IPPROTO_TCP
		iocp/bind g-iocp as int-ptr! fd
		socket/bind fd 0 type

		socket/connect2 fd saddr addr-sz create-tcp-data port fd
	]

	tcp-server: func [
		port	[red-object!]
		num		[red-integer!]
		/local
			fd	[integer!]
			sd	[sockdata!]
	][
		#if debug? = yes [if verbose > 0 [io/debug "tcp server"]]

		fd: socket/create AF_INET SOCK_STREAM IPPROTO_TCP
		socket/bind fd num/value AF_INET
		sd: as sockdata! create-tcp-data port fd
		socket/listen fd 1024 as iocp-data! sd
		#if OS = 'Windows [socket/acceptex fd :sd/addr :sd/addr-sz as iocp-data! sd]
		iocp/bind g-iocp as int-ptr! fd
	]

	;-- actions

	open: func [
		red-port	[red-object!]
		new?		[logic!]
		read?		[logic!]
		write?		[logic!]
		seek?		[logic!]
		async?		[logic!]
		allow		[red-value!]
		return:		[red-value!]
		/local
			values	[red-value!]
			spec	[red-object!]
			state	[red-handle!]
			host	[red-string!]
			num		[red-integer!]
			n		[integer!]
			n-port	[integer!]
			addr	[c-string!]
			addrbuf [sockaddr_in6! value]
			type	[integer!]
			sz		[integer!]
	][
		#if debug? = yes [if verbose > 0 [io/debug "tcp/open"]]

		values: object/get-values red-port
		state: as red-handle! values + port/field-state
		if TYPE_OF(state) <> TYPE_NONE [return as red-value! red-port]

		spec:	as red-object! values + port/field-spec
		values: object/get-values spec
		host:	as red-string! values + 2
		num:	as red-integer! values + 3		;-- port number

		either zero? string/rs-length? host [	;-- e.g. open tcp://:8000
			tcp-server red-port num
		][
			n: -1
			addr: unicode/to-utf8 host :n
			either TYPE_OF(num) = TYPE_INTEGER [n-port: num/value][n-port: 80]
			either all [addr/1 = #"[" addr/n = #"]"][
				type: AF_INET6
				addr/n: #"^@"
				addr: addr + 1
				sz: size? sockaddr_in6!
			][
				type: AF_INET
				sz: size? sockaddr_in!
			]

			either 1 = inet_pton type addr :addrbuf/sin_addr [
				make-sockaddr as sockaddr_in! :addrbuf addr n-port type
				tcp-client red-port as sockaddr_in! :addrbuf sz type
			][
				dns-device/resolve-name red-port addr n-port as int-ptr! :event-handler
			]
		]
		as red-value! red-port
	]

	open?: func [
		red-port	[red-object!]
		return:		[red-value!]
	][
		io/port-open? red-port
	]

	close: func [
		red-port	[red-object!]
		return:		[red-value!]
		/local
			data	[iocp-data!]
	][
		#if debug? = yes [if verbose > 0 [io/debug "tcp/close"]]
		data: io/close-port red-port
		if data <> null [
			socket/close as-integer data/device
			data/device: IO_INVALID_DEVICE
			#if OS = 'Windows [free as byte-ptr! data]
		]
		as red-value! red-port
	]

	insert: func [
		port		[red-object!]
		value		[red-value!]
		part		[red-value!]
		only?		[logic!]
		dup			[red-value!]
		append?		[logic!]
		return:		[red-value!]
		/local
			data	[sockdata!]
			bin		[red-binary!]
			n		[integer!]
			s		[series!]
	][
		bin: as red-binary! value
		switch TYPE_OF(value) [
			TYPE_BINARY [
				io/pin-memory bin/node
			]
			TYPE_STRING [
				n: -1
				bin/node: unicode/str-to-utf8 as red-string! value :n no
				bin/head: 0
				s: GET_BUFFER(bin)
				s/tail: as cell! (as byte-ptr! s/tail) + n
				io/pin-memory bin/node
			]
			default [return as red-value! port]
		]

		data: get-tcp-data port
		data/send-buf: bin/node

		socket/send
			as-integer data/device
			binary/rs-head bin
			binary/rs-length? bin
			as iocp-data! data
		as red-value! port
	]

	copy: func [
		red-port	[red-object!]
		new			[red-value!]
		part		[red-value!]
		deep?		[logic!]
		types		[red-value!]
		return:		[red-value!]
		/local
			data	[iocp-data!]
			buf		[red-binary!]
			s		[series!]
	][
		buf: as red-binary! (object/get-values red-port) + port/field-data
		if TYPE_OF(buf) <> TYPE_BINARY [
			binary/make-at as cell! buf SOCK_READBUF_SZ
		]
		buf/head: 0
		io/pin-memory buf/node
		s: GET_BUFFER(buf)
		data: as iocp-data! get-tcp-data red-port
		socket/recv as-integer data/device as byte-ptr! s/offset s/size data
		as red-value! red-port
	]

	table: [
		;-- Series actions --
		null			;append
		null			;at
		null			;back
		null			;change
		null			;clear
		:copy
		null			;find
		null			;head
		null			;head?
		null			;index?
		:insert
		null			;length?
		null			;move
		null			;next
		null			;pick
		null			;poke
		null			;put
		null			;remove
		null			;reverse
		null			;select
		null			;sort
		null			;skip
		null			;swap
		null			;tail
		null			;tail?
		null			;take
		null			;trim
		;-- I/O actions --
		null			;create
		:close
		null			;delete
		null			;modify
		:open
		:open?
		null			;query
		null			;read
		null			;rename
		null			;update
		null			;write
	]
]

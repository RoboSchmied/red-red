Red/System [
	Title:	"IOCP on Unix"
	Author: "Xie Qingtian"
	File: 	%iocp.reds
	Tabs: 	4
	Rights: "Copyright (C) 2019 Red Foundation. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/red/red/blob/master/BSL-License.txt
	}
	NOTE: {
		This is not a completed IOCP implementation.
	}
]

iocp-event-handler!: alias function! [
	data		[int-ptr!]
]

iocp!: alias struct! [
	maxn		[integer!]
	epfd		[integer!]				;-- the epoll fd
	events		[epoll_event!]			;-- the events
	nevents		[integer!]				;-- the events count
	pair-1		[integer!]
	pair-2		[integer!]
	ready-socks	[deque!]				;-- a queue for ready socket
	posted?		[logic!]
	n-ports		[integer!]
]

pending-data!: alias struct! [
	header			[list-entry! value]
	buffer			[byte-ptr!]
	buflen			[integer!]
]

#define IOCP_DATA_FIELDS [
	io-port			[iocp!]				;--	iocp! handle
	device			[handle!]			;-- device handle. e.g. socket
	event-handler	[iocp-event-handler!]
	event			[integer!]
	transferred		[integer!]			;-- number of bytes transferred
	read-buf		[byte-ptr!]
	read-buflen		[integer!]
	write-buf		[byte-ptr!]
	write-buflen	[integer!]		
	type			[integer!]			;@@ change it to uint16
	state			[integer!]			;@@ change it to uint16
	accept-sock		[integer!]
	pending-read	[pending-data!]
	pending-write	[pending-data!]
]

iocp-data!: alias struct! [
	IOCP_DATA_FIELDS
]

sockdata!: alias struct! [
	IOCP_DATA_FIELDS
	port		[red-object! value]		;-- red port! cell
	send-buf	[node!]					;-- send buffer
	addr		[sockaddr_in6! value]	;-- IPv4 or IPv6 address
	addr-sz		[integer!]
	addrinfo	[int-ptr!]
]

tls-data!: alias struct! [
	IOCP_DATA_FIELDS
	port		[red-object! value]		;-- red port! cell
	send-buf	[node!]					;-- send buffer
	addr		[sockaddr_in6! value]	;-- IPv4 or IPv6 address
	addr-sz		[integer!]
	ssl			[int-ptr!]
	certs		[node!]
]

udp-data!: alias struct! [
	iocp		[iocp-data! value]
	port		[red-object! value]		;-- red port! cell
	send-buf	[node!]					;-- send buffer
	addr		[sockaddr_in6! value]	;-- IPv4 or IPv6 address
	addr-sz		[integer!]
]

dns-data!: alias struct! [
	IOCP_DATA_FIELDS
	port		[red-object! value]		;-- red port! cell
	send-buf	[node!]
	addr		[sockaddr_in6! value]	;-- IPv4 or IPv6 address
	addr-sz		[integer!]
	addrinfo	[int-ptr!]
]

file-data!: alias struct! [
	IOCP_DATA_FIELDS
	port		[red-object! value]		;-- red port! cell
	flags		[integer!]
	buffer		[node!]					;-- buffer node!
]

iocp: context [
	verbose: 0

	create: func [
		return: [iocp!]
		/local
			p	[iocp!]
			ptr [iocp-data!]
	][
		signal SIGPIPE SIG_IGN
		errno: get-errno-ptr
		p: as iocp! zero-alloc size? iocp!
		p/maxn: 65536

		#either OS = 'macOS [
			p/epfd: LibC.kqueue
		][
			p/epfd: epoll_create1 00080000h
		]
		assert p/epfd > 0

		p/ready-socks: deque/create 1024

		if -1 = socketpair 1 SOCK_STREAM 0 :p/pair-1 [
			probe "!!! create pair fail !!!"
		]
		socket/set-nonblocking p/pair-1
		socket/set-nonblocking p/pair-2

		ptr: as iocp-data! zero-alloc size? iocp-data!
		ptr/device: as handle! p/pair-2
		ptr/event: IO_EVT_PULSE
		add p p/pair-2 EPOLLIN or EPOLLET ptr
		p
	]
 
	close: func [
		p [iocp!]
	][
		#if debug? = yes [io/debug "iocp/close"]

		LibC.close p/pair-1
		LibC.close p/pair-2
		LibC.close p/epfd
		if p/events <> null [
			free as byte-ptr! p/events
		]
		free as byte-ptr! p
	]

	post: func [
		p		[iocp!]
		data	[iocp-data!]
		return:	[logic!]
	][
		probe ["iocp/post: " data/event]
		deque/push p/ready-socks as int-ptr! data
		unless p/posted? [
			p/posted?: yes
			LibC.send p/pair-1 as byte-ptr! "p" 1 0
		]
		true
	]

	bind: func [
		"bind a device handle to the I/O completion port"
		p		[iocp!]
		handle	[int-ptr!]
	][
		p/n-ports: p/n-ports + 1
	]

	read-io: func [
		data	[iocp-data!]
		return: [integer!]
		/local
			n	[integer!]
			td [tls-data!]
			udp [udp-data!]
	][
		switch data/type [
			IOCP_TYPE_TCP [
				n: LibC.recv as-integer data/device data/read-buf data/read-buflen 0
				if n < 0 [
					n: either errno/value = EAGAIN [-1][0]
				]
				n
			]
			IOCP_TYPE_TLS [
				td: as tls-data! data
				IODebug(["SSL_read" td/ssl data/read-buf data/read-buflen])
				n: SSL_read td/ssl data/read-buf data/read-buflen
				if n <= 0 [
					n: SSL_get_error td/ssl n
					tls/check-errors n
					n: switch n [
						SSL_ERROR_WANT_READ
						SSL_ERROR_WANT_WRITE [-1]
						;SSL_ERROR_ZERO_RETURN [0]
						default [
							td/state: td/state or IO_STATE_ERROR
							0
						]
					]
				]
				n
			]
			IOCP_TYPE_UDP IOCP_TYPE_DNS [
				udp: as udp-data! data
				libC.recvfrom
					as-integer data/device
					data/read-buf
					data/read-buflen
					0
					as sockaddr_in6! :udp/addr
					:udp/addr-sz
			]
		]
	]

	_write-io: func [
		data	[iocp-data!]
		return: [integer!]
		/local
			n	[integer!]
			td	[tls-data!]
			udp [udp-data!]
	][
		if zero? data/write-buflen [return 0]

		switch data/type [
			IOCP_TYPE_TCP [
				n: LibC.send as-integer data/device data/write-buf data/write-buflen 0
				if n < 0 [
					n: either errno/value = EAGAIN [0][
						switch errno/value [
							EACCES	[probe "TCP send: No permission"]
							default [0]
						]
						-1
					]
				]
				n
			]
			IOCP_TYPE_TLS [
				td: as tls-data! data
				IODebug(["SSL_write" td/ssl data/write-buf data/write-buflen])
				n: SSL_write td/ssl data/write-buf data/write-buflen
				if n <= 0 [
					n: SSL_get_error td/ssl n
					n: either any [
						n = SSL_ERROR_WANT_WRITE
						n = SSL_ERROR_WANT_READ
					][0][
						tls/check-errors n
						td/state: td/state or IO_STATE_ERROR
						-1
					]
				]
				n
			]
			IOCP_TYPE_UDP IOCP_TYPE_DNS [
				udp: as udp-data! data
				n: libC.sendto
					as-integer data/device
					data/write-buf
					data/write-buflen
					0
					as sockaddr_in6! :udp/addr
					udp/addr-sz
				if n < 0 [
					n: either errno/value = EAGAIN [0][
						switch errno/value [
							EACCES	[probe "UDP send: No permission"]
							default [0]
						]
						-1
					]
				]
				n
			]
		]
	]

	write-io: func [
		data	[iocp-data!]		;-- write until finish or error
		return: [integer!]			;-- >= 0 success the bytes has been written, -1 error
		/local
			cnt		[integer!]
			n		[integer!]
			io-port	[iocp!]
			sock	[integer!]
			state	[integer!]
			length	[integer!]
	][
		IODebug("iocp/write-io")
		io-port: data/io-port
		sock: as-integer data/device
		state: data/state
		length: data/write-buflen
		cnt: 0
		forever [
			n: _write-io data
			case [
				n = length [
					data/event: IO_EVT_WRITE
					data/state: state and (not IO_STATE_WRITING)
					iocp/post io-port data
					cnt: cnt + n
					break
				]
				n >= 0 [
					case [
						zero? (state and IO_STATE_RW) [
							data/state: state or IO_STATE_PENDING_WRITE
							iocp/add io-port sock EPOLLOUT or EPOLLET data
						]
						state and EPOLLOUT = 0 [
							data/state: state or IO_STATE_PENDING_WRITE
							iocp/modify io-port sock EPOLLIN or EPOLLOUT or EPOLLET data
						]
						true [data/state: state or IO_STATE_WRITING]
					]
					if zero? n [break]

					state: data/state
					data/write-buf: data/write-buf + n
					length: length - n
					data/write-buflen: length
					cnt: cnt + n
				]
				true [	;-- error
					data/event: IO_EVT_CLOSE
					break
				]
			]
		]
		cnt
	]

#either OS = 'macOS [
	#define IOCP_READ_ACTION? [filter = EVFILT_READ]
	#define IOCP_WRITE_ACTION? [filter = EVFILT_WRITE]
][
	#define IOCP_READ_ACTION? [e/events and EPOLLIN <> 0]
	#define IOCP_WRITE_ACTION? [e/events and EPOLLOUT <> 0]
]

	wait: func [
		"wait I/O completion events and dispatch them"
		p			[iocp!]
		timeout		[integer!]			;-- time in ms, -1: infinite
		return:		[integer!]
		/local
			queue	[deque!]
			cnt		[integer!]
			i		[integer!]
			e		[epoll_event!]
			data	[iocp-data!]
			td		[tls-data!]
			n		[integer!]
			err		[integer!]
			sock	[integer!]
			datalen [integer!]
			state	[integer!]
			fd		[integer!]
			#if OS = 'macOS [
			filter	[integer!]
			flags	[integer!]
			_tm		[timespec! value]
			tm		[timespec!]
			]
	][
		#if debug? = yes [if verbose > 0 [io/debug "iocp/wait"]]

		err: 0
		if null? p/events [
			p/nevents: 512
			p/events: as epoll_event! allocate p/nevents * size? epoll_event!
		]
		queue: p/ready-socks

	#either OS = 'macOS [
		either timeout < 0 [
			tm: null
		][
			tm: :_tm
			tm/sec: timeout / 1000
			tm/nsec: timeout % 1000 * 1000000
		]

		cnt: LibC.kevent p/epfd null 0 p/events p/nevents tm
	][
		cnt: epoll_wait p/epfd p/events p/nevents timeout
	]
		if cnt < 0 [				;-- error
			either errno/value = EINTR [return p/n-ports][
				IODebug(["wait error: " errno/value])
				return 0
			]
		]

		if cnt = p/nevents [		;-- TBD: extend events buffer
			0
		]

		i: 0
		while [i < cnt][
			e: p/events + i
			data: as iocp-data! e/udata
			either data/event = IO_EVT_PULSE [
				datalen: 0
				n: LibC.recv as-integer data/device as byte-ptr! :datalen 4 0
				assert n = 1

				p/posted?: no
				n: queue/size

				loop n [
					data: as iocp-data! deque/take queue
					if data/type = IOCP_TYPE_DNS [
						either data/event = IO_EVT_WRITE [
							dns/recv as dns-data! data
							continue
						][
							either dns/parse-data as dns-data! data [
								data/event: IO_EVT_LOOKUP
							][continue]
						]
					]

					#if debug? = yes [probe ["pluse event: " data/event]]
					data/event-handler as int-ptr! data
				]
			][
			#either OS = 'macOS [
				filter: e/filter and FFFFh
				flags: e/filter >>> 16
				;probe ["ready event: " filter " " flags]
			][
				;probe ["ready event: " e/events]
			]
				
				state: data/state

			#if OS = 'macOS [
				if flags and EV_ERROR <> 0 [
					probe "kqueue error"
					i: i + 1 continue
				]
				if flags and EV_EOF <> 0 [
					probe "kqueue: socket close"
					i: i + 1 continue
				]
			]
				if all [
					data/event = IO_EVT_CONNECT
					state and IO_STATE_CONNECTED = 0
				][
					IODebug("check-connect")
					if 1 = socket/check-connect as sockdata! data [
						i: i + 1 continue
					]
				]

				if all [
					data/type = IOCP_TYPE_TLS
					state and IO_STATE_TLS_DONE = 0
					data/event <> IO_EVT_CLOSE
				][
					td: as tls-data! data
					if null? td/ssl [
						if data/event = IO_EVT_CONNECT [
							tls/create td yes
						]
						if data/event = IO_EVT_ACCEPT [
							td: as tls-data! copy-memory 
									allocate size? tls-data!	;-- dst
									as byte-ptr! data			;-- src
									size? tls-data!
							fd: socket/accept as-integer td/device :td/addr :td/addr-sz
							if zero? fd [
								free as byte-ptr! td
								i: i + 1
								continue
							]
							bind p as int-ptr! fd
							td/accept-sock: as-integer td/device
							td/device: as int-ptr! fd
							td/state: td/state and IO_STATE_CLIENT
							tls/create td no
							data: as iocp-data! td
						]
					]
					if zero? tls/negotiate td [
						i: i + 1
						continue
					]
				]

				if all [
					IOCP_READ_ACTION?
					state and IO_STATE_READING <> 0
				][
					either null? data/pending-read [
						n: read-io data
						if n >= 0 [
							data/state: state and (not IO_STATE_READING)
							data/transferred: n
							data/event: IO_EVT_READ
							either data/type = IOCP_TYPE_DNS [
								if dns/parse-data as dns-data! data [
									data/type: IOCP_TYPE_TCP
									data/event: IO_EVT_LOOKUP
								]
							][data/event-handler as int-ptr! data]
						]
					][
						0 ;TBD
					]
				]
				if all [
					IOCP_WRITE_ACTION?
					state and IO_STATE_WRITING <> 0
				][
					if all [
						data/type = IOCP_TYPE_TLS
						state and IO_STATE_CLOSING <> 0
					][
						tls/free-handle as tls-data! data
						i: i + 1
						continue
					]

					either null? data/pending-write [
						write-io data
						if data/state and IO_STATE_WRITING <> 0 [
							i: i + 1
							continue
						]
					][
						0 ;; TBD
					]
				]
				if data/type = IOCP_TYPE_DNS [
					i: i + 1
					continue
				]
				if data/event > IO_EVT_WRITE [
					data/event-handler as int-ptr! data
				]
				if data/device = IO_INVALID_DEVICE [
					free as byte-ptr! data
				]
			]
			i: i + 1
		]
IODebug(["wait done: " p/n-ports])
		p/n-ports
	]

	create-pending: func [
		buffer	[byte-ptr!]
		len		[integer!]
		return: [pending-data!]
		/local
			pending [pending-data!]
	][
		pending: as pending-data! allocate size? pending-data!
		dlink/init as list-entry! pending
		pending/buffer: buffer		;-- save previous data
		pending/buflen: len
		pending
	]

	add-pending: func [
		data	[iocp-data!]
		buffer	[byte-ptr!]
		len		[integer!]
		evt		[integer!]		;-- can only be READ and WRITE event
		/local
			pending	[pending-data!]
	][
		switch evt [
			IO_EVT_READ [
				pending: data/pending-read
				if null? pending [
					pending: create-pending data/read-buf data/read-buflen
					data/pending-read: pending
					data/read-buflen: 1
				]
				data/read-buflen: data/read-buflen + 1
			]
			IO_EVT_WRITE [
				pending: data/pending-write
				if null? pending [
					pending: create-pending data/read-buf data/read-buflen
					data/pending-write: pending
					data/write-buflen: 1
				]
				data/write-buflen: data/write-buflen + 1
			]
			default [exit]
		]
		dlink/append
			as list-entry! pending
			as list-entry! create-pending buffer len
	]

	push-data: func [
		p		[iocp!]
		sdata	[iocp-data!]
	][
		deque/push p/ready-socks as int-ptr! sdata
	]

	pulse: func [
		p		[iocp!]
	][
		LibC.send p/pair-1 as byte-ptr! "p" 1 0
	]

	kill: func [
		p	[iocp!]
	][
		LibC.send p/pair-1 as byte-ptr! "k" 1 0
	]

#either OS = 'macOS [
	_modify: func [
		kqfd	[integer!]
		evs		[kevent!]
		cnt		[integer!]
		/local
			res	[integer!]
	][
		res: LibC.kevent kqfd evs cnt null 0 null
		if res < 0 [
			probe ["change kevent failed, errno: " errno/value]
		]
	]

	add: func [
		p		[iocp!]
		sock	[integer!]
		events	[integer!]
		data	[iocp-data!]
		/local
			e2	[kevent! value]
			e1	[kevent! value]
			e	[kevent!]
			ev	[integer!]
			n	[integer!]
	][
		ev: EV_ADD
		if events and EPOLLET <> 0 [ev: ev or EV_CLEAR]

		e: as kevent! :e1
		n: 0
		if events and EPOLLIN <> 0 [
			EV_SET(e sock EVFILT_READ ev 0 null data)
			n: n + 1
			e: e + 1
		]
		if events and EPOLLOUT <> 0 [
			EV_SET(e sock EVFILT_WRITE ev 0 null data)
			n: n + 1
		]
		_modify p/epfd :e1 n
	]

	remove: func [
		p		[iocp!]
		sock	[integer!]
		events	[integer!]
		data	[iocp-data!]
		/local
			e2	[kevent! value]
			e1	[kevent! value]
			e	[kevent!]
			ev	[integer!]
			n	[integer!]
	][
		ev: EV_DELETE
		e: as kevent! :e1
		n: 0
		if events and EPOLLIN <> 0 [
			EV_SET(e sock EVFILT_READ ev 0 null data)
			n: n + 1
			e: e + 1
		]
		if events and EPOLLOUT <> 0 [
			EV_SET(e sock EVFILT_WRITE ev 0 null data)
			n: n + 1
		]
		_modify p/epfd :e1 n
	]

	modify: func [
		p		[iocp!]
		sock	[integer!]
		events	[integer!]
		data	[iocp-data!]
	][
		add p sock events data
	]
][
	_modify: func [
		epfd	[integer!]
		sock	[integer!]
		evts	[integer!]
		data	[iocp-data!]
		op		[integer!]
		/local
			ev	[epoll_event! value]
	][
		ev/udata: as int-ptr! data
		ev/events: evts
		IODebug(["epoll_ctl fd: " sock " op: " op " evts: " as int-ptr! evts])
		if 0 <> epoll_ctl epfd op sock :ev [
			IODebug(["epoll_ctl error! fd: " sock " op: " op " evts: " as int-ptr! evts " err: " errno/value])
			exit
		]
	]

	add: func [
		p		[iocp!]
		sock	[integer!]
		events	[integer!]
		data	[iocp-data!]
	][
		_modify p/epfd sock events data EPOLL_CTL_ADD
	]

	remove: func [
		p		[iocp!]
		sock	[integer!]
		events	[integer!]
		data	[iocp-data!]
	][
		_modify p/epfd sock events data EPOLL_CTL_DEL
	]

	modify: func [
		p		[iocp!]
		sock	[integer!]
		events	[integer!]
		data	[iocp-data!]
	][
		_modify p/epfd sock events data EPOLL_CTL_MOD
	]
]]
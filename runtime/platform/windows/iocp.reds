Red/System [
	Title:	"IOCP on Windows"
	Author: "Xie Qingtian"
	File: 	%iocp.reds
	Tabs: 	4
	Rights: "Copyright (C) 2018 Red Foundation. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/red/red/blob/master/BSL-License.txt
	}
]

iocp-event-handler!: alias function! [
	data		[int-ptr!]
]

iocp!: alias struct! [
	maxn	[integer!]
	port	[int-ptr!]
	events	[OVERLAPPED_ENTRY!]
	evt-cnt [integer!]
	n-ports [integer!]						;-- number of port!
]

#define IOCP_DATA_FIELDS [
	Internal		[int-ptr!]				;-- inline OVERLAPPED struct begin
	InternalHigh	[int-ptr!]
	Offset			[integer!]				;-- or Pointer [int-ptr!]
	OffsetHigh		[integer!]
	hEvent			[int-ptr!]				;-- inline OVERLAPPED struct end
	;--
	device			[handle!]				;-- device handle
	event-handler	[iocp-event-handler!]
	event			[integer!]
	type			[integer!]				;-- TCP, UDP, TLS, etc
	state			[integer!]
	transferred		[integer!]				;-- number of bytes transferred
	accept-sock		[integer!]
]

iocp-data!: alias struct! [
	IOCP_DATA_FIELDS
]

sockdata!: alias struct! [
	IOCP_DATA_FIELDS
	port		[red-object! value]		;-- red port! cell
	flags		[integer!]
	send-buf	[node!]					;-- send buffer
	addr		[sockaddr_in6! value]	;-- IPv4 or IPv6 address
	addr2		[sockaddr_in! value]	;-- 16 bytes
	addr-sz		[integer!]
	addrinfo	[int-ptr!]
]

tls-data!: alias struct! [
	IOCP_DATA_FIELDS
	port		[red-object! value]		;-- red port! cell
	flags		[integer!]
	send-buf	[node!]					;-- send buffer
	tls-buf		[byte-ptr!]				;-- encode data in this buffer
	tls-extra	[byte-ptr!]				;-- leftover data after decoding
	extra-sz	[integer!]				;-- size of the extra buffer
	head		[integer!]				;-- head of the send-buf
	sent-sz		[integer!]
	buf-len		[integer!]				;-- number of bytes in the read buffer
	addr		[sockaddr_in6! value]	;-- IPv4 or IPv6 address
	addr2		[sockaddr_in! value]	;-- 16 bytes
	addr-sz		[integer!]
	credential	[SecHandle! value]		;-- credential handle
	security	[int-ptr!]				;-- security context handle lower
	security2	[int-ptr!]				;-- security context handle upper
	cert-ctx	[CERT_CONTEXT]			;-- certificate with a key
	root-store	[handle!]				;-- root certs for client mode
	;-- SecPkgContext_StreamSizes
	ctx-max-msg	[integer!]
	ctx-header	[integer!]
	ctx-trailer	[integer!]
]

udp-data!: alias struct! [
	iocp		[iocp-data! value]
	port		[red-object! value]		;-- red port! cell
	flags		[integer!]
	send-buf	[node!]					;-- send buffer
	addr		[sockaddr_in6! value]	;-- IPv4 or IPv6 address
	addr-sz		[integer!]
]

dns-data!: alias struct! [
	IOCP_DATA_FIELDS
	port		[red-object! value]		;-- red port! cell
	flags		[integer!]
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
	][
		p: as iocp! zero-alloc size? iocp!
		p/maxn: 65536
		p/port: CreateIoCompletionPort INVALID_HANDLE null null 0
		assert p/port <> INVALID_HANDLE
		p
	]

	close: func [
		p [iocp!]
	][
		#if debug? = yes [print-line "iocp/close"]

		CloseHandle p/port
		p/port: null
		if p/events <> null [
			free as byte-ptr! p/events
			p/events: null
		]
		free as byte-ptr! p
	]

	post: func [
		p		[iocp!]
		data	[iocp-data!]
		return:	[logic!]
	][
		0 <> PostQueuedCompletionStatus p/port data/transferred null as OVERLAPPED! data
	]

	bind: func [
		"bind a device handle to the I/O completion port"
		p		[iocp!]
		handle	[int-ptr!]
		/local
			port [int-ptr!]
	][
		port: CreateIoCompletionPort handle p/port null 0
		either port = p/port [
			p/n-ports: p/n-ports + 1
		][
			probe "iocp bind error"
		]
	]

	#define NEXT_EVENT [i: i + 1 continue]

	wait: func [
		"wait I/O completion events and dispatch them"
		p			[iocp!]
		timeout		[integer!]			;-- time in ms, -1: infinite
		return:		[integer!]
		/local
			res		[integer!]
			cnt		[integer!]
			err		[integer!]
			i		[integer!]
			fd		[integer!]
			e		[OVERLAPPED_ENTRY!]
			data	[iocp-data!]
			td		[tls-data!]
			evt		[integer!]
	][
		if null? p/events [
			p/evt-cnt: 512
			p/events: as OVERLAPPED_ENTRY! allocate p/evt-cnt * size? OVERLAPPED_ENTRY!
		]

		cnt: 0
		res: GetQueuedCompletionStatusEx p/port p/events p/evt-cnt :cnt timeout no
	
		if zero? res [
			err: GetLastError
			;IODebug(["GetQueuedCompletionStatusEx: " err])
			return 0
		]

		if cnt = p/evt-cnt [			;-- TBD: extend events buffer
			0
		]

		i: 0
		while [i < cnt][
			e: p/events + i
			data: as iocp-data! e/lpOverlapped
			if data/device = IO_INVALID_DEVICE [
				free as byte-ptr! data
				NEXT_EVENT
			]

			data/transferred: e/dwNumberOfBytesTransferred

			evt: data/event
			switch data/type [
				IOCP_TYPE_DNS [
					switch evt [
						IO_EVT_WRITE [
							dns/recv as dns-data! data
							NEXT_EVENT
						]
						IO_EVT_READ [
							either dns/parse-data as dns-data! data [
								data/event: IO_EVT_LOOKUP
							][
								NEXT_EVENT
							]
						]
						default [0]
					]
				]
				IOCP_TYPE_TLS [
					either data/state and IO_STATE_TLS_DONE <> 0 [	;-- handshake done
						switch evt [
							IO_EVT_READ [
								unless tls/decode as tls-data! data [NEXT_EVENT]
							]
							IO_EVT_WRITE [
								if tls/send-data as tls-data! data [NEXT_EVENT]
							]
							IO_EVT_ACCEPT [
								data/state: IO_STATE_TLS_DONE
								td: as tls-data! data
								io/unpin-memory td/send-buf
							]
							default [0]
						]
					][
						td: as tls-data! data
						if all [evt = IO_EVT_ACCEPT null? td/cert-ctx][
							;-- swap accepted socket and the server socket
							;-- we'll do the negotiate through the accepted socket
							fd: data/accept-sock
							data/accept-sock: as-integer data/device
							data/device: as int-ptr! fd
							bind p as int-ptr! fd
						]
						if zero? tls/negotiate td [NEXT_EVENT]
					]
				]
				default [0]
			]

			if evt > 0 [data/event-handler as int-ptr! data]
			i: i + 1
		]
		p/n-ports
	]
]
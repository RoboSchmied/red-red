Red/System [
	Title:	"Async DNS implementation on POSIX"
	Author: "Xie Qingtian"
	File: 	%dns.reds
	Tabs: 	4
	Rights: "Copyright (C) 2018 Red Foundation. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/red/red/blob/master/BSL-License.txt
	}
]

dns: context [
	gstate:	as int-ptr! 0

	server-list: as int-ptr! 0
	server-idx: 0
	xid: 0
	datalen: 0

	getaddrinfo: func [
		addr			[c-string!]
		port			[integer!]
		domain			[integer!]
		dns-data		[dns-data!]
		/local
			state		[int-ptr!]
			r			[res_state!]
			res			[integer!]
			len			[integer!]
			buffer		[byte-ptr!]
			fd			[integer!]
			n			[integer!]
			server		[int-ptr!]
			dns-addr	[sockaddr_in!]
			s			[series!]
	][
		if null? gstate [
			gstate: as int-ptr! allocate 512
			n: res_ninit gstate
			assert zero? n
		]
		state: gstate

		domain: either domain = AF_INET [1][28]
		buffer: allocate DNS_PACKET_SZ
		len: res_nmkquery state 0 addr 1 domain null 0 null buffer DNS_PACKET_SZ

		if len <= 0 [
			probe "Could not create DNS query!"
		]

		dns-data/addrinfo: as int-ptr! buffer
		fd: socket/create AF_INET SOCK_DGRAM IPPROTO_UDP
		iocp/bind dns-data/io-port as int-ptr! fd

		r: as res_state! state

		dns-data/addr-sz: size? sockaddr_in!
		dns-addr: as sockaddr_in! :dns-data/addr
		copy-memory as byte-ptr! dns-addr as byte-ptr! :r/nsaddr1 size? sockaddr_in!

		dns-data/device: as int-ptr! fd
		socket/send fd buffer len as iocp-data! dns-data
	]

	recv: func [
		dns-data	[dns-data!]
		return:		[integer!]
		/local
			s		[series!]
	][
		io/pin-memory dns-data/send-buf
		s: as series! dns-data/send-buf/value
		socket/recv
			as-integer dns-data/device
			as byte-ptr! s/offset
			DNS_PACKET_SZ
			as iocp-data! dns-data
	]

	parse-data: func [
		data	[dns-data!]
		return: [logic!]
		/local
			s		[series!]
			pp		[ptr-ptr!]
			res		[integer!]
			server	[int-ptr!]
			dns-addr [sockaddr_in!]
			port	[integer!]
			record	[byte-ptr!]
			msg		[ns_msg! value]
			blob-sz	[integer!]
			blob	[byte-ptr!]
			n		[integer!]
			i		[integer!]
			type	[int-ptr!]
			rdata	[int-ptr!]
			str-addr [c-string!]
	][
		io/unpin-memory data/send-buf
		s: as series! data/send-buf/value

		res: ns_initparse as byte-ptr! s/offset data/transferred :msg
		res: ns_msg_getflag msg 9	;-- ns_msg_getflag
		n: msg/counts >>> 16

		record: as byte-ptr! system/stack/allocate 262
		str-addr: as c-string! system/stack/allocate 12
		i: 0
		while [i < n][
			if 0 <> ns_parserr msg 1 i record [break]
			i: i + 1
			type: as int-ptr! record + 1026
			switch type/value and FFFFh [
				1	[		;-- IPv4 address
					pp: as ptr-ptr! record + 1040
					rdata: pp/value
					dns-addr: as sockaddr_in! :data/addr
					dns-addr/sin_addr: rdata/value
#if debug? = yes [
	inet_ntop AF_INET as byte-ptr! rdata str-addr INET6_ADDRSTRLEN
	print-line ["DNS resolved: " str-addr]
]
					return yes
				]
				28	[		;-- IPv6 address
					0
				]
				default [0]
			]
		]
		no
	]
]
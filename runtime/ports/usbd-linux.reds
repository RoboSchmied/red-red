Red/System [
	Title:	"usb port! implementation on Linux"
	Author: "bitbegin"
	File: 	%usbd-linux.reds
	Tabs: 	4
	Rights: "Copyright (C) 2018 Red Foundation. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/red/red/blob/master/BSL-License.txt
	}
]

#include %usbd-common.reds

#define pthread_t int-ptr!

PIPE-PAIR!: alias struct! [
	in						[integer!]
	out						[integer!]
]

ONESHOT-THREAD!: alias struct! [
	buffer					[byte-ptr!]					;-- data
	buflen					[integer!]
	actual-len				[integer!]
	thread					[pthread_t]
	;mutex					[pthread_mutex_t value]		; pthread_mutex_t is int
	;interface				[integer!]
	trigger?				[logic!]					;-- trigger kevent
	udata					[int-ptr!]					;-- for kqueue udata
	pipe					[PIPE-PAIR! value]
]

usb-device: context [

	device-list: declare list-entry!

	#define kHidDriver					"usbhid"
	#define O_ACCMODE					3

	#define _IO_H						[(as integer! #"H")]
	#define HIDIOCGRDESCSIZE			[_IOR(_IO_H 1 4)]
	#define HID_MAX_DESCRIPTOR_SIZE		4096
	#define HIDIOCGRDESC				[_IOR(_IO_H 2 (HID_MAX_DESCRIPTOR_SIZE + 4))]

	#define _IO_U						[(as integer! #"U")]
	#define USBDEVFS_BULK				[_IOWR(_IO_U 2 16)]



	POLL-FD!: alias struct! [
		fd						[integer!]
		events					[integer!]  ;--events and revents
	]


	USBDEVFS-BULKTRANSFER!: alias struct! [
		ep						[integer!]
		len						[integer!]
		timeout					[integer!]
		data					[byte-ptr!]
	]


	#import [
		LIBC-file cdecl [
			pthread_create: "pthread_create" [
				restrict		[int-ptr!]
				restrict1		[int-ptr!]
				restrict2		[int-ptr!]
				restrict3		[int-ptr!]
				return:			[integer!]
			]
			pthread_join: "pthread_join" [
				thread		[int-ptr!]
				retval		[int-ptr!]
				return:		[integer!]
			]
		]
		"libudev.so.1" cdecl [
			udev_new: "udev_new" [
				return:			[int-ptr!]
			]
			udev_ref: "udev_ref" [
				udev			[int-ptr!]
				return:			[int-ptr!]
			]
			udev_unref: "udev_unref" [
				udev			[int-ptr!]
				return:			[int-ptr!]
			]
			udev_enumerate_new: "udev_enumerate_new" [
				udev			[int-ptr!]
				return:			[int-ptr!]
			]
			udev_enumerate_unref: "udev_enumerate_unref" [
				udev_enumerate	[int-ptr!]
				return:			[int-ptr!]
			]
			udev_enumerate_add_match_subsystem: "udev_enumerate_add_match_subsystem" [
				udev_enumerate	[int-ptr!]
				subsystem		[c-string!]
				return:			[integer!]
			]
			udev_enumerate_add_match_parent: "udev_enumerate_add_match_parent" [
				udev_enumerate	[int-ptr!]
				parent			[int-ptr!]
				return:			[integer!]
			]
			udev_enumerate_add_match_property: "udev_enumerate_add_match_property" [
				udev_enumerate	[int-ptr!]
				property		[c-string!]
				value			[c-string!]
				return:			[integer!]
			]
			udev_enumerate_scan_devices: "udev_enumerate_scan_devices" [
				udev_enumerate	[int-ptr!]
				return:			[integer!]
			]
			udev_enumerate_get_list_entry: "udev_enumerate_get_list_entry" [
				udev_enumerate	[int-ptr!]
				return:			[int-ptr!]
			]
			udev_list_entry_get_next: "udev_list_entry_get_next" [
				list_entry		[int-ptr!]
				return:			[int-ptr!]
			]
			udev_list_entry_get_name: "udev_list_entry_get_name" [
				list_entry		[int-ptr!]
				return:			[c-string!]
			]
			udev_device_new_from_syspath: "udev_device_new_from_syspath" [
				udev 			[int-ptr!]
				syspath			[c-string!]
				return:			[int-ptr!]
			]
			udev_device_get_devnode: "udev_device_get_devnode" [
				udev_device		[int-ptr!]
				return:			[c-string!]
			]
			udev_device_get_parent_with_subsystem_devtype: "udev_device_get_parent_with_subsystem_devtype" [
				udev_device		[int-ptr!]
				subsystem		[c-string!]
				devtype			[c-string!]
				return:			[int-ptr!]
			]
			udev_device_unref: "udev_device_unref" [
				udev_device		[int-ptr!]
				return:			[int-ptr!]
			]
			udev_device_get_sysattr_value: "udev_device_get_sysattr_value" [
				dev				[int-ptr!]
				sysattr			[c-string!]
				return:			[c-string!]
			]
			udev_device_get_property_value: "udev_device_get_property_value" [
				dev				[int-ptr!]
				key				[c-string!]
				return:			[c-string!]
			]
		]
	]

	enum-usb-device: func [
		device-list				[list-entry!]
		id?						[logic!]
		_vid					[integer!]
		_pid					[integer!]
		/local
			udev				[int-ptr!]
			enumerate			[int-ptr!]
			result				[integer!]
			devices				[int-ptr!]
			dev_list_entry		[int-ptr!]
			sysfs_path			[c-string!]
			device				[int-ptr!]
			dev_path			[c-string!]
			attr				[c-string!]
			vid					[integer!]
			pid					[integer!]
			serial				[c-string!]
			name				[c-string!]
			pNode				[DEVICE-INFO-NODE!]
			buf					[byte-ptr!]
			len					[integer!]
	][
		udev: udev_new
		if udev = null [exit]
		enumerate: udev_enumerate_new udev
		if enumerate = null [
			udev_unref udev
			exit
		]
		;result: udev_enumerate_add_match_subsystem enumerate "usb"
		result: udev_enumerate_add_match_property enumerate "DEVTYPE" "usb_device"
		if result <> 0 [
			udev_enumerate_unref enumerate
			udev_unref udev
			exit
		]
		udev_enumerate_scan_devices enumerate
		devices: udev_enumerate_get_list_entry enumerate
		dev_list_entry: devices
		while [dev_list_entry <> null] [
			sysfs_path: udev_list_entry_get_name dev_list_entry
			device: udev_device_new_from_syspath udev sysfs_path
			dev_path: udev_device_get_devnode device
			if dev_path = null [
				udev_device_unref device
				dev_list_entry: udev_list_entry_get_next dev_list_entry
				continue
			]

			attr: udev_device_get_sysattr_value device "idVendor"
			if attr = null [
				udev_device_unref device
				dev_list_entry: udev_list_entry_get_next dev_list_entry
				continue
			]
			;print-line attr
			vid: 65535
			sscanf [attr "%x" :vid]
			attr: udev_device_get_sysattr_value device "idProduct"
			if attr = null [
				udev_device_unref device
				dev_list_entry: udev_list_entry_get_next dev_list_entry
				continue
			]
			;print-line attr
			pid: 65535
			sscanf [attr "%x" :pid]
			if all [
				id?
				any [
					_vid <> vid
					_pid <> pid
				]
			][
				udev_device_unref device
				dev_list_entry: udev_list_entry_get_next dev_list_entry
				continue
			]
			serial: udev_device_get_sysattr_value device "serial"
			name: udev_device_get_sysattr_value device "product"

			pNode: as DEVICE-INFO-NODE! allocate size? DEVICE-INFO-NODE!
			if pNode = null [
				udev_device_unref device
				dev_list_entry: udev_list_entry_get_next dev_list_entry
				continue
			]
			set-memory as byte-ptr! pNode null-byte size? DEVICE-INFO-NODE!
			dlink/init pNode/interface-entry
			pNode/vid: vid
			pNode/pid: pid
			len: (length? sysfs_path) + 1
			buf: allocate len
			copy-memory buf as byte-ptr! sysfs_path len
			pNode/syspath: as c-string! buf

			len: (length? dev_path) + 1
			buf: allocate len
			copy-memory buf as byte-ptr! dev_path len
			pNode/path: as c-string! buf
			;print-line pNode/path
			if name <> null [
				len: (length? name) + 1
				buf: allocate len
				copy-memory buf as byte-ptr! name len
				pNode/name: buf
				pNode/name-len: len - 1
				;print-line name
			]
			if serial <> null [
				len: (length? serial) + 1
				buf: allocate len
				copy-memory buf as byte-ptr! serial len
				pNode/serial-num: as c-string! buf
			]
			enum-children pNode/interface-entry device dev_path vid pid

			dlink/append device-list as list-entry! pNode

			udev_device_unref device
			dev_list_entry: udev_list_entry_get_next dev_list_entry
		]


		udev_enumerate_unref enumerate
		udev_unref udev
	]

	enum-children: func [
		list					[list-entry!]
		parent					[int-ptr!]
		parent-path				[c-string!]
		vid						[integer!]
		pid						[integer!]
		/local
			udev				[int-ptr!]
			enumerate			[int-ptr!]
			result				[integer!]
			devices				[int-ptr!]
			dev_list_entry		[int-ptr!]
			sysfs_path			[c-string!]
			device				[int-ptr!]
			dev_path			[c-string!]
			attr				[c-string!]
			nmi					[integer!]
			buf					[byte-ptr!]
			len					[integer!]
			len2				[integer!]
			pNode				[INTERFACE-INFO-NODE!]
	][
		udev: udev_new
		if udev = null [exit]
		enumerate: udev_enumerate_new udev
		if enumerate = null [
			udev_unref udev
			exit
		]
		;result: udev_enumerate_add_match_subsystem enumerate "usb"
		result: udev_enumerate_add_match_property enumerate "DEVTYPE" "usb_interface"
		if result <> 0 [
			udev_enumerate_unref enumerate
			udev_unref udev
			exit
		]
		result: udev_enumerate_add_match_parent enumerate parent
		if result <> 0 [
			udev_enumerate_unref enumerate
			udev_unref udev
			exit
		]
		udev_enumerate_scan_devices enumerate
		devices: udev_enumerate_get_list_entry enumerate
		dev_list_entry: devices
		while [dev_list_entry <> null] [
			sysfs_path: udev_list_entry_get_name dev_list_entry
			device: udev_device_new_from_syspath udev sysfs_path
			attr: udev_device_get_sysattr_value device "bInterfaceNumber"
			if attr = null [
				udev_device_unref device
				dev_list_entry: udev_list_entry_get_next dev_list_entry
				continue
			]
			nmi: 255
			sscanf [attr "%4hhx" :nmi]
			if nmi = 255 [
				udev_device_unref device
				dev_list_entry: udev_list_entry_get_next dev_list_entry
				continue
			]
			attr: udev_device_get_sysattr_value device "interface"
			if attr = null [
				udev_device_unref device
				dev_list_entry: udev_list_entry_get_next dev_list_entry
				continue
			]
			len: (length? attr) + 1
			buf: allocate len
			copy-memory buf as byte-ptr! attr len
			pNode: as INTERFACE-INFO-NODE! allocate size? INTERFACE-INFO-NODE!
			if pNode = null [
				udev_device_unref device
				dev_list_entry: udev_list_entry_get_next dev_list_entry
				continue
			]
			set-memory as byte-ptr! pNode null-byte size? INTERFACE-INFO-NODE!
			pNode/interface-num: nmi
			pNode/name: buf
			pNode/name-len: len - 1
			pNode/hType: DRIVER-TYPE-WINUSB

			attr: udev_device_get_property_value device "DRIVER"
			if attr <> null [
				len: length? attr
				len2: length? kHidDriver
				if all [
					len = len2
					0 = compare-memory as byte-ptr! attr as byte-ptr! kHidDriver len
				][
					if hid-device? pNode device vid pid [
						pNode/hType: DRIVER-TYPE-HIDUSB
					]
				]
			]
			dlink/append list as list-entry! pNode
			;print-line "child"
			;print-line sysfs_path

			len: (length? sysfs_path) + 1
			buf: allocate len
			copy-memory buf as byte-ptr! sysfs_path len
			pNode/syspath: as c-string! buf
			if pNode/path = null [
				len: (length? parent-path) + 1
				buf: allocate len
				copy-memory buf as byte-ptr! parent-path len
				pNode/path: as c-string! buf
			]

			udev_device_unref device
			dev_list_entry: udev_list_entry_get_next dev_list_entry
		]

		udev_enumerate_unref enumerate
		udev_unref udev
	]

	hid-device?: func [
		pNode					[INTERFACE-INFO-NODE!]
		parent					[int-ptr!]
		vid						[integer!]
		pid						[integer!]
		return:					[logic!]
		/local
			udev				[int-ptr!]
			enumerate			[int-ptr!]
			result				[integer!]
			devices				[int-ptr!]
			dev_list_entry		[int-ptr!]
			sysfs_path			[c-string!]
			device				[int-ptr!]
			dev_path			[c-string!]
			buf					[byte-ptr!]
			len					[integer!]
	][
		udev: udev_new
		if udev = null [return false]
		enumerate: udev_enumerate_new udev
		if enumerate = null [
			udev_unref udev
			return false
		]
		result: udev_enumerate_add_match_subsystem enumerate "hidraw"
		if result <> 0 [
			udev_enumerate_unref enumerate
			udev_unref udev
			return false
		]
		result: udev_enumerate_add_match_parent enumerate parent
		if result <> 0 [
			udev_enumerate_unref enumerate
			udev_unref udev
			return false
		]
		udev_enumerate_scan_devices enumerate
		devices: udev_enumerate_get_list_entry enumerate
		dev_list_entry: devices
		if dev_list_entry <> null [
			sysfs_path: udev_list_entry_get_name dev_list_entry
			device: udev_device_new_from_syspath udev sysfs_path
			dev_path: udev_device_get_devnode device
			if dev_path = null [
				udev_device_unref device
				udev_enumerate_unref enumerate
				udev_unref udev
				return false
			]
			len: (length? sysfs_path) + 1
			buf: allocate len
			copy-memory buf as byte-ptr! sysfs_path len
			pNode/syspath: as c-string! buf
			len: (length? dev_path) + 1
			buf: allocate len
			copy-memory buf as byte-ptr! dev_path len
			pNode/path: as c-string! buf
			udev_device_unref device
		]
		udev_enumerate_unref enumerate
		udev_unref udev
		;print-line pNode/path
		;print-line "is hid"
		true
	]

	enum-all-devices: does [
		enum-usb-device device-list no -1 -1
	]

	find-usb: func [
		device-list				[list-entry!]
		vid						[integer!]
		pid						[integer!]
		sn						[c-string!]
		mi						[integer!]
		col						[integer!]
		return:					[DEVICE-INFO-NODE!]
		/local
			entry				[list-entry!]
			dnode				[DEVICE-INFO-NODE!]
			len					[integer!]
			len2				[integer!]
			children			[list-entry!]
			child-entry			[list-entry!]
			inode				[INTERFACE-INFO-NODE!]
	][
		entry: device-list/next
		while [entry <> device-list][
			dnode: as DEVICE-INFO-NODE! entry
			if all [
				dnode/vid = vid
				dnode/pid = pid
			][
				len: length? sn
				len2: length? dnode/serial-num
				if all [
					len <> 0
					len = len2
					0 = compare-memory as byte-ptr! sn as byte-ptr! dnode/serial-num len
				][
					children: dnode/interface-entry
					child-entry: children/next
					while [child-entry <> children][
						inode: as INTERFACE-INFO-NODE! child-entry
						if any [
							mi = 255
							inode/interface-num = 255
						][
							dlink/remove-entry device-list entry/prev entry/next
							clear-device-list device-list
							dnode/interface: inode
							return dnode
						]
						if mi = inode/interface-num [
							dlink/remove-entry device-list entry/prev entry/next
							clear-device-list device-list
							dnode/interface: inode
							return dnode
						]
						child-entry: child-entry/next
					]
				]
			]
			entry: entry/next
		]
		clear-device-list device-list
		null
	]

	open: func [
		vid						[integer!]
		pid						[integer!]
		sn						[c-string!]
		mi						[integer!]
		col						[integer!]
		return:					[DEVICE-INFO-NODE!]
		/local
			dnode				[DEVICE-INFO-NODE!]
			inode				[INTERFACE-INFO-NODE!]
	][
		clear-device-list device-list
		enum-usb-device device-list yes vid pid
		dnode: find-usb device-list vid pid sn mi col
		if dnode = null [return null]
		inode: dnode/interface
		if USB-ERROR-OK <> open-inteface inode [
			free-device-info-node dnode
			return null
		]
		print-line "open"
		print-line inode/hDev
		;print-line inode/hInf
		dnode
	]

	open-inteface: func [
		pNode					[INTERFACE-INFO-NODE!]
		return:					[USB-ERROR!]
	][
		case [
			pNode/hType = DRIVER-TYPE-WINUSB [
				return open-winusb pNode
			]
			pNode/hType = DRIVER-TYPE-HIDUSB [
				return open-hidusb pNode
			]
			true [
				return USB-ERROR-UNSUPPORT
			]
		]
	]

	open-winusb: func [
		pNode					[INTERFACE-INFO-NODE!]
		return:					[USB-ERROR!]
		/local
			fd					[integer!]
			;buf					[byte-ptr!]
			wthread				[ONESHOT-THREAD!]
			rthread				[ONESHOT-THREAD!]
			result				[integer!]
	][
		print-line "winusb"
		print-line pNode/syspath
		print-line pNode/path
		fd: _open pNode/path O_RDWR S_IREAD or S_IWRITE or S_IRGRP or S_IWGRP or S_IROTH
		if fd < 0 [
			perror "open"
			return USB-ERROR-OPEN
		]
		pNode/hDev: fd
		;lseek fd 0 0
		;buf: allocate 128
		;set-memory buf null-byte 128
		;print-line _read fd buf 128
		;dump-hex buf

		wthread: as ONESHOT-THREAD! allocate size? ONESHOT-THREAD!
		if wthread = null [
			_close fd
			perror "allocate"
			return USB-ERROR-INIT
		]
		set-memory as byte-ptr! wthread null-byte size? ONESHOT-THREAD!
		result: _pipe :wthread/pipe
		if result <> 0 [
			_close fd
			free as byte-ptr! wthread
			perror "create pipe"
			return USB-ERROR-INIT
		]
		pNode/write-thread: as int-ptr! wthread

		rthread: as ONESHOT-THREAD! allocate size? ONESHOT-THREAD!
		if rthread = null [
			_close fd
			_close wthread/pipe/in
			_close wthread/pipe/out
			free as byte-ptr! wthread
			perror "allocate"
			return USB-ERROR-INIT
		]
		set-memory as byte-ptr! rthread null-byte size? ONESHOT-THREAD!
		result: _pipe :rthread/pipe
		if result <> 0 [
			_close fd
			_close wthread/pipe/in
			_close wthread/pipe/out
			free as byte-ptr! wthread
			_close rthread/pipe/in
			_close rthread/pipe/out
			free as byte-ptr! rthread
			perror "create pipe"
			return USB-ERROR-INIT
		]
		pNode/read-thread: as int-ptr! rthread

		USB-ERROR-OK
	]

	open-hidusb: func [
		pNode					[INTERFACE-INFO-NODE!]
		return:					[USB-ERROR!]
		/local
			fd					[integer!]
			desc-size			[integer!]
			rpt-desc			[int-ptr!]
			result				[integer!]
			buf					[byte-ptr!]
			wthread				[ONESHOT-THREAD!]
			rthread				[ONESHOT-THREAD!]
	][
		print-line "hidusb"
		print-line pNode/syspath
		print-line pNode/path
		fd: _open pNode/path O_RDWR S_IREAD or S_IWRITE or S_IRGRP or S_IWGRP or S_IROTH
		if fd < 0 [
			perror "open"
			return USB-ERROR-OPEN
		]
		pNode/hDev: fd
		desc-size: 0
		result: _ioctl fd HIDIOCGRDESCSIZE as byte-ptr! :desc-size
		if result <> 0 [
			_close fd
			perror "HIDIOCGRDESCSIZE"
			return USB-ERROR-INIT
		]
		print-line desc-size
		rpt-desc: as int-ptr! allocate 4100
		rpt-desc/1: desc-size
		result: _ioctl fd HIDIOCGRDESC as byte-ptr! rpt-desc
		if result <> 0 [
			_close fd
			free as byte-ptr! rpt-desc
			perror "HIDIOCGRDESC"
			return USB-ERROR-INIT
		]
		buf: allocate 4 + desc-size
		copy-memory buf as byte-ptr! rpt-desc 4 + desc-size
		pNode/report-desc: buf
		free as byte-ptr! rpt-desc

		wthread: as ONESHOT-THREAD! allocate size? ONESHOT-THREAD!
		if wthread = null [
			_close fd
			perror "allocate"
			return USB-ERROR-INIT
		]
		set-memory as byte-ptr! wthread null-byte size? ONESHOT-THREAD!
		result: _pipe :wthread/pipe
		if result <> 0 [
			_close fd
			_close wthread/pipe/in
			_close wthread/pipe/out
			free as byte-ptr! wthread
			perror "create pipe"
			return USB-ERROR-INIT
		]
		pNode/write-thread: as int-ptr! wthread

		rthread: as ONESHOT-THREAD! allocate size? ONESHOT-THREAD!
		if rthread = null [
			_close fd
			_close wthread/pipe/in
			_close wthread/pipe/out
			free as byte-ptr! wthread
			perror "allocate"
			return USB-ERROR-INIT
		]
		set-memory as byte-ptr! rthread null-byte size? ONESHOT-THREAD!
		result: _pipe :rthread/pipe
		if result <> 0 [
			_close fd
			_close wthread/pipe/in
			_close wthread/pipe/out
			free as byte-ptr! wthread
			_close rthread/pipe/in
			_close rthread/pipe/out
			free as byte-ptr! rthread
			perror "create pipe"
			return USB-ERROR-INIT
		]
		pNode/read-thread: as int-ptr! rthread

		USB-ERROR-OK
	]

	close-interface: func [
		pNode					[INTERFACE-INFO-NODE!]
	][
		if pNode/hDev <> 0 [
			_close pNode/hDev
			pNode/hDev: 0
		]
	]

	write-data: func [
		pNode					[INTERFACE-INFO-NODE!]
		buf						[byte-ptr!]
		buflen					[integer!]
		plen					[int-ptr!]
		data					[int-ptr!]
		timeout					[integer!]
		return:					[integer!]
		/local
			wthread				[ONESHOT-THREAD!]
	][
		case [
			pNode/hType = DRIVER-TYPE-WINUSB [
				wthread: as ONESHOT-THREAD! pNode/write-thread
				if wthread/thread <> null [return -1]
				wthread/udata: data
				wthread/buffer: buf
				wthread/buflen: buflen
				pthread_create :wthread/thread
					null
					as int-ptr! :winusb-write-thread
					as int-ptr! pNode
				return 0
			]
			pNode/hType = DRIVER-TYPE-HIDUSB [
				wthread: as ONESHOT-THREAD! pNode/write-thread
				if wthread/thread <> null [return -1]
				wthread/udata: data
				wthread/buffer: buf
				wthread/buflen: buflen
				pthread_create :wthread/thread
					null
					as int-ptr! :hidusb-write-thread
					as int-ptr! pNode
				return 0
			]
			true [
				return -1
			]
		]
		-1
	]

	winusb-write-thread: func [
		[cdecl]
		param					[int-ptr!]
		return:					[int-ptr!]
		/local
			pNode				[INTERFACE-INFO-NODE!]
			wthread				[ONESHOT-THREAD!]
			urb					[USBDEVFS-BULKTRANSFER! value]
			buffer				[byte-ptr!]
			p					[byte-ptr!]
			len					[integer!]
	][
		pNode: as INTERFACE-INFO-NODE! param
		wthread: as ONESHOT-THREAD! pNode/write-thread
		urb/ep: 1
		urb/len: wthread/buflen
		urb/timeout: -1
		urb/data: wthread/buffer
		if 0 > _ioctl pNode/hDev USBDEVFS_BULK as byte-ptr! :urb [
			perror "winusb write"
		]
		wthread/actual-len: wthread/buflen
		_write wthread/pipe/out as byte-ptr! pNode 4
		wthread/thread: null
		null
	]

	hidusb-write-thread: func [
		[cdecl]
		param					[int-ptr!]
		return:					[int-ptr!]
		/local
			pNode				[INTERFACE-INFO-NODE!]
			wthread				[ONESHOT-THREAD!]
			buffer				[byte-ptr!]
			p					[byte-ptr!]
			len					[integer!]
	][
		pNode: as INTERFACE-INFO-NODE! param
		wthread: as ONESHOT-THREAD! pNode/write-thread
		buffer: wthread/buffer
		either buffer/1 = null-byte [
			p: buffer + 1
			len: wthread/buflen - 1
		][
			p: buffer
			len: wthread/buflen
		]
		wthread/actual-len: _write pNode/hDev p len
		_write wthread/pipe/out as byte-ptr! pNode 4
		wthread/thread: null
		null
	]

	read-data: func [
		pNode					[INTERFACE-INFO-NODE!]
		buf						[byte-ptr!]
		buflen					[integer!]
		plen					[int-ptr!]
		data					[int-ptr!]
		timeout					[integer!]
		return:					[integer!]
		/local
			rthread				[ONESHOT-THREAD!]
	][
		case [
			pNode/hType = DRIVER-TYPE-WINUSB [
				rthread: as ONESHOT-THREAD! pNode/read-thread
				if rthread/thread <> null [return -1]
				rthread/udata: data
				rthread/buffer: buf
				rthread/buflen: buflen
				pthread_create :rthread/thread
					null
					as int-ptr! :winusb-read-thread
					as int-ptr! pNode
				return 0
			]
			pNode/hType = DRIVER-TYPE-HIDUSB [
				rthread: as ONESHOT-THREAD! pNode/read-thread
				if rthread/thread <> null [return -1]
				rthread/udata: data
				rthread/buffer: buf
				rthread/buflen: buflen
				pthread_create :rthread/thread
					null
					as int-ptr! :hidusb-read-thread
					as int-ptr! pNode
				return 0
			]
		]
		-1
	]

	winusb-read-thread: func [
		[cdecl]
		param					[int-ptr!]
		return:					[int-ptr!]
		/local
			pNode				[INTERFACE-INFO-NODE!]
			rthread				[ONESHOT-THREAD!]
			urb					[USBDEVFS-BULKTRANSFER! value]
			buffer				[byte-ptr!]
			p					[byte-ptr!]
			len					[integer!]
	][
		pNode: as INTERFACE-INFO-NODE! param
		rthread: as ONESHOT-THREAD! pNode/read-thread
		urb/ep: 81h
		urb/len: rthread/buflen
		urb/timeout: -1
		urb/data: rthread/buffer
		if 0 > _ioctl pNode/hDev USBDEVFS_BULK as byte-ptr! :urb [
			perror "winusb read"
		]
		rthread/actual-len: rthread/buflen
		_write rthread/pipe/out as byte-ptr! pNode 4
		rthread/thread: null
		null
	]

	hidusb-read-thread: func [
		[cdecl]
		param					[int-ptr!]
		return:					[int-ptr!]
		/local
			pNode				[INTERFACE-INFO-NODE!]
			rthread				[ONESHOT-THREAD!]
	][
		pNode: as INTERFACE-INFO-NODE! param
		rthread: as ONESHOT-THREAD! pNode/read-thread
		rthread/actual-len: _read pNode/hDev rthread/buffer rthread/buflen
		_write rthread/pipe/out as byte-ptr! pNode 4
		rthread/thread: null
		null
	]

	init: does [
		dlink/init device-list
	]
]
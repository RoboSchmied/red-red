usb: open usb://VID=1209&PID=53C1&MI=00&SN=EF3ADD96F01D8B1975B6FE11
probe usb
buffer: make binary! 64
append buffer #{3F2323}
append/dup buffer #{00} 61

usb/state/pipe: 'interrupt
usb/state/read-size: 64
usb/awake: func [event /local port] [
    print ["=== usb event:" event/type]
    port: event/port
    switch event/type [
        lookup [open port]
        connect [
            print "connect"
            insert port buffer
        ]
        read [
            probe "usb read done"
            probe port/data
            copy port
        ]
        wrote [
            probe "usb write done"
            copy port
        ]
    ]
    false
]
wait usb
close usb
Red [
    title: "Basic TCP test client"
]

do [

debug: :print
;debug: :comment

max-count: 100000
count: 0
total: 0

print "TCP client"

client: open tcp://127.0.0.1:8000

b: make binary! size: 10000
loop size [append b random 255]
insert b skip (to binary! length? b) 4

start: now/precise
mbps: "?"

client/awake: func [event /local port] [
    debug ["=== Client event:" event/type]
    port: event/port
    switch event/type [
        lookup [open port]
        connect [insert port b]
        read [
	        probe "client read done"
	        probe port/data
            if port/data/2 [
                print ["ERROR in response" total]
                close port
                return true
            ]
            either port/data = #{0f} [
                count: count + 1
                total: total + size + 4
                if count // 1000 = 0 [
                    t: to float! difference now/precise start
                    mbps: round (total / t * 10 / 1024 / 1024)
                ]
                print [count round (total / 1024 / 1024) "MB" mbps "Mbps"]
                either count < max-count [
                    insert port b
                ][
                    close port
                    return true
                ]
            ][
                copy port
            ]
        ]
        wrote [probe "client write done" copy port]
    ]
    false
]

wait client
close client
print "Done"

]

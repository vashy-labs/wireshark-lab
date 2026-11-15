# Capture files

The files named in each scenario of the book. Open them in Wireshark 4.x (File → Open).

`scenario-22.keys` is the TLS key log for Scenario 22. It only decrypts that lab capture.

### Part I · TCP performance

| Scenario | Files |
|---|---|
| 1 · The download that crawls | `scenario-01.pcapng`, `scenario-01-baseline.pcapng` |
| 2 · Everything is slow from the new branch | `scenario-02.pcapng`, `scenario-02-fixed.pcapng`, `scenario-02-baseline.pcapng` |
| 3 · The transfer that keeps stopping | `scenario-03.pcapng`, `scenario-03-baseline.pcapng` |
| 4 · The network is slow - or is it? | `scenario-04.pcapng`, `scenario-04-baseline.pcapng` |
| 5 · Small pages load, big pages hang | `scenario-05.pcapng`, `scenario-05-fixed.pcapng`, `scenario-05-server.pcapng`, `scenario-05-baseline.pcapng` |
| 6 · Forty milliseconds, every time | `scenario-06.pcapng`, `scenario-06-fixed.pcapng`, `scenario-06-baseline.pcapng` |
| 7 · A fast link that will not go fast | `scenario-07.pcapng`, `scenario-07-baseline.pcapng` |
| 8 · It drops when nobody is typing | `scenario-08.pcapng`, `scenario-08-fixed.pcapng`, `scenario-08-server.pcapng`, `scenario-08-baseline.pcapng` |

### Part II · Connectivity and addressing

| Scenario | Files |
|---|---|
| 9 · One PC cannot leave the building | `scenario-09.pcapng`, `scenario-09-mask.pcapng`, `scenario-09-baseline.pcapng` |
| 10 · Two machines, one address | `scenario-10.pcapng`, `scenario-10-dad.pcapng`, `scenario-10-baseline.pcapng` |
| 11 · The PC that gives itself an address | `scenario-11.pcapng`, `scenario-11-server.pcapng`, `scenario-11-baseline.pcapng` |
| 12 · The wrong network after lunch | `scenario-12.pcapng`, `scenario-12-baseline.pcapng` |
| 13 · Ping works, the website does not | `scenario-13.pcapng`, `scenario-13-reset.pcapng`, `scenario-13-closed.pcapng`, `scenario-13-reject.pcapng`, `scenario-13-baseline.pcapng` |
| 14 · The packet that never arrives | `scenario-14.pcapng`, `scenario-14-core.pcapng` |

### Part III · DNS

| Scenario | Files |
|---|---|
| 15 · Five seconds before anything happens | `scenario-15.pcapng`, `scenario-15-dns1.pcapng`, `scenario-15-baseline.pcapng` |
| 16 · Half the office lost the intranet | `scenario-16.pcapng`, `scenario-16-compare.pcapng`, `scenario-16-baseline.pcapng` |
| 17 · Big answers get lost | `scenario-17.pcapng`, `scenario-17-edns.pcapng`, `scenario-17-baseline.pcapng` |

### Part IV · HTTP and TLS

| Scenario | Files |
|---|---|
| 18 · Bad gateway | `scenario-18.pcapng`, `scenario-18-slow.pcapng`, `scenario-18-backend.pcapng`, `scenario-18-baseline.pcapng`, `scenario-18-slow-backend.pcapng` |
| 19 · "Your connection is not private" | `scenario-19.pcapng`, `scenario-19-tls12.pcapng`, `scenario-19-baseline.pcapng` |
| 20 · The old client that cannot connect | `scenario-20.pcapng`, `scenario-20-fixed.pcapng`, `scenario-20-baseline.pcapng` |
| 21 · The wrong site answers | `scenario-21.pcapng`, `scenario-21-baseline.pcapng` |
| 22 · Reading what is encrypted | `scenario-22.keys`, `scenario-22.pcapng`, `scenario-22-with-keys.pcapng` |

### Part V · Applications and services

| Scenario | Files |
|---|---|
| 23 · Copying a folder takes all afternoon | `scenario-23.pcapng`, `scenario-23-lan.pcapng`, `scenario-23-zip.pcapng` |
| 24 · The call connects, one side hears nothing | `scenario-24.pcapng`, `scenario-24-home.pcapng`, `scenario-24-baseline.pcapng`, `scenario-24-baseline-home.pcapng` |
| 25 · Robot voices | `scenario-25.pcapng`, `scenario-25-baseline.pcapng` |
| 26 · Slow every day at two o'clock | `scenario-26.pcapng` |

### Part VI · Seeing an attack in a capture

| Scenario | Files |
|---|---|
| 27 · Someone is trying every door | `scenario-27.pcapng`, `scenario-27-baseline.pcapng` |
| 28 · Who is the gateway now? | `scenario-28.pcapng`, `scenario-28-baseline.pcapng` |
| 29 · A thousand wrong passwords | `scenario-29.pcapng` |
| 30 · Quiet, regular and suspicious | `scenario-30.pcapng` |

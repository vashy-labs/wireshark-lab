# Wireshark Troubleshooting Lab Scenarios

Capture files and lab scripts for the book **Wireshark Troubleshooting Lab Scenarios – Find
Real-World Network Problems from Packet Captures** by Vashy.

The book has 30 support tickets. Each one comes with packet captures, a step-by-step investigation
in Wireshark, the root cause and the fix.

## What is here

| Folder | Contents |
|---|---|
| [`captures`](captures) | the capture files named in each scenario (`scenario-01.pcapng`, ...) |
| [`lab`](lab) | the scripts that made every capture, to run in your own Linux VM |
| [`extras`](extras) | the display filter cheat sheet from Appendix B |

## Get the captures

Click **Code → Download ZIP** on this page and unzip it, or use Git:

```text
git clone https://github.com/vashy-labs/wireshark-lab.git
```

Then open a file from the `captures` folder in Wireshark. [`captures/README.md`](captures/README.md)
lists the files for each scenario.

The screenshots in the book show Wireshark 4.6.9 on Windows. Other 4.x versions look much the same.

## Build the lab yourself

Appendix C of the book has the full instructions. In short, on an **Ubuntu Server 24.04** virtual
machine (2 CPUs, 4 GB memory, 20 GB disk):

```text
git clone https://github.com/vashy-labs/wireshark-lab.git
mv wireshark-lab/lab ~/wireshark-lab
cd ~/wireshark-lab
sudo ./setup-lab.sh          # once; then log out and back in
sudo ./scenarios/s01.sh      # run a scenario
```

Each script builds a small network from Linux network namespaces, creates the problem, captures
it and writes the files to `~/wireshark-lab/captures`. Your captures tell the same story as the
book's, but frame numbers and times will differ.

Run the lab only in a virtual machine you can rebuild. The scripts need root, change network
settings and stop the system's own nginx and Samba services.

## The scenarios

**Part I · TCP performance**

1. The download that crawls
2. Everything is slow from the new branch
3. The transfer that keeps stopping
4. The network is slow - or is it?
5. Small pages load, big pages hang
6. Forty milliseconds, every time
7. A fast link that will not go fast
8. It drops when nobody is typing

**Part II · Connectivity and addressing**

9. One PC cannot leave the building
10. Two machines, one address
11. The PC that gives itself an address
12. The wrong network after lunch
13. Ping works, the website does not
14. The packet that never arrives

**Part III · DNS**

15. Five seconds before anything happens
16. Half the office lost the intranet
17. Big answers get lost

**Part IV · HTTP and TLS**

18. Bad gateway
19. "Your connection is not private"
20. The old client that cannot connect
21. The wrong site answers
22. Reading what is encrypted

**Part V · Applications and services**

23. Copying a folder takes all afternoon
24. The call connects, one side hears nothing
25. Robot voices
26. Slow every day at two o'clock

**Part VI · Seeing an attack in a capture**

27. Someone is trying every door
28. Who is the gateway now?
29. A thousand wrong passwords
30. Quiet, regular and suspicious

## A note on Part VI

The scenarios in Part VI show what a port scan, ARP spoofing, password guessing and a beacon look
like in a capture, so that you can recognise them. All traffic is made inside the isolated lab,
against the lab's own machines, with made-up names and passwords. Use these tools and techniques
only on networks and machines you are responsible for.

## Licence

The scripts are under the MIT licence (see [LICENSE](LICENSE)). The capture files may be used
freely for learning and teaching; please mention the book when you share them.

Wireshark is a registered trademark of the Wireshark Foundation. This book and repository are not
affiliated with or endorsed by the Wireshark Foundation.

## Problems and corrections

Found a mistake, or a script that does not run? Please open an issue on this repository.

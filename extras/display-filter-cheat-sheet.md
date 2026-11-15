# Display filter cheat sheet

From Appendix B of *Wireshark Troubleshooting Lab Scenarios*. The last column is the scenario where the filter is used.

Every general-purpose filter used in the book, grouped by protocol, with the scenarios that use it. Filters that name one scenario's own addresses are left out here; you find them at the end of each scenario. Chapter A explains the operators (`==`, `&&`, `!` and so on); `or` and two vertical bars mean the same, and the screenshots often use the bars. Appendix A shows how to use the same filters with tshark.

## Frames, Ethernet and ARP

| Filter | Shows | Scenario |
|------------------------------|----------------------------------|--------|
| `frame.len >= 1500` | full-size packets | 5 |
| `arp` | all ARP requests and replies | 9, 28 |
| `arp.duplicate-address-detected` | the frames Wireshark flagged | 10, 28 |
| `arp or tcp.flags.reset == 1` | the ARP race and its resets together | 10 |
| `arp.isprobe` | ARP Probes, a machine checking an address before using it | 10 |
| `frame.time_delta_displayed > 1` | gaps longer than one second in the current view | 22 |
| `frame.time_delta_displayed > 0.05` | with an RTP filter: gaps over 50 ms | 25 |
| `arp.isgratuitous` | gratuitous ARP announcements | 28 |
| `frame.time_delta_displayed` (as a column) | the gap between displayed packets | 30 |

## IP and ICMP

| Filter | Shows | Scenario |
|------------------------------|----------------------------------|--------|
| `ip.flags.df == 1 && ip.len > 1400` | packets that may not be fragmented and are too big for a 1,400-byte link | 5 |
| `icmp.type == 3 && icmp.code == 4` | "fragmentation needed" messages | 5 |
| `icmp or tcp` | hides ARP and IPv6 background packets (`or` can be written as a double bar) | 13 |
| `icmp.type == 3` | ICMP "destination unreachable" messages of every kind | 13, 24, 28 |
| `ip.ttl` (as a column) | how far each packet has travelled | 13, 14 |
| `icmp.type == 11` | Time-to-live exceeded messages | 14 |
| `icmp.type == 8` | ping requests | 14 |
| `ip.ttl < 5` | packets about to expire | 14 |
| `icmp.type == 3 && icmp.code == 1` | Host unreachable messages | 16 |

## TCP

| Filter | Shows | Scenario |
|------------------------------|----------------------------------|--------|
| `tcp.analysis.flags && !tcp.analysis.window_update` | every TCP problem packet | 1 |
| `tcp.analysis.lost_segment` | gaps in the sequence numbers | 1 |
| `tcp.analysis.fast_retransmission` | segments resent after duplicate ACKs | 1 |
| `tcp.analysis.out_of_order` | late segments Wireshark could not classify as retransmissions | 1 |
| `tcp.analysis.duplicate_ack` | repeated ACKs for the same byte | 1 |
| `tcp.flags.syn == 1 && tcp.flags.ack == 0` | the first packet of every TCP connection | 2, 13, 27 |
| `tcp.analysis.initial_rtt` | the round-trip time measured from the handshake (use as a column) | 2 |
| `tcp.stream == 0` | all packets of the first connection in the capture | 2, 4, 6 |
| `tcp.analysis.window_full` | the sender has used up the receiver's window | 3 |
| `tcp.analysis.zero_window` | the receiver announces Win=0 | 3 |
| `tcp.analysis.window_update` | the receiver announces more room | 3 |
| `tcp.analysis.keep_alive` | zero-length probes (keep-alives and Linux window probes) | 3, 8 |
| `tcp.options.sack.dsack` | D-SACKs: the receiver got something twice | 3 |
| `tcp.time_delta > 1` | packets that follow more than a second of silence on their connection | 4 |
| `tcp.stream == 1` | the second connection in the capture (streams count from 0) | 5, 18 |
| `tcp.flags.syn == 1` | the handshake, with each side's MSS | 5, 7 |
| `tcp.analysis.retransmission` | what the sender had to repeat | 5, 8 |
| `tcp.time_delta > 0.035` | packets that follow a pause of 35 ms or more on their connection | 6 |
| `tcp.len > 0 && tcp.len < 100` | small data packets | 6 |
| `tcp.len == 0 && tcp.flags == 0x010` | bare ACKs | 6 |
| `tcp.flags.syn == 1 && !tcp.options.wscale.shift` | handshake packets without a window scale option | 7 |
| `tcp.window_size == 65535` | packets announcing the largest unscaled window | 7 |
| `tcp.window_size_scalefactor == -2` | packets on connections where scaling is not used | 7 |
| `tcp` | TCP only: hides ARP and IPv6 background packets | 8 |
| `tcp.time_delta > 15` | packets that follow more than 15 seconds of silence on their connection | 8 |
| `tcp.analysis.keep_alive_ack` | the answers to them | 8 |
| `tcp.analysis.retransmission && tcp.flags.syn == 1` | SYNs that had to be repeated | 13 |
| `tcp.flags.reset == 1` | resets | 13 |
| `tcp.port == 53 && tcp.flags.syn == 1` | attempts to reach DNS over TCP | 17 |
| `tcp.port == 445` | SMB traffic, including plain TCP packets | 23 |
| `tcp.analysis.initial_rtt > 0.1` | connections whose handshake took over 100 ms | 26 |
| `tcp.flags.syn == 1 && tcp.flags.ack == 1` | answers from open ports | 27 |
| `tcp.flags.syn == 1 && tcp.window_size_value == 1024` | SYNs with a scanner's typical window | 27 |

## UDP and DHCP

| Filter | Shows | Scenario |
|------------------------------|----------------------------------|--------|
| `dhcp` | all DHCP messages | 11 |
| `dhcp.option.dhcp == 1` | Discovers (2 Offer, 3 Request, 5 ACK, 6 NAK) | 11 |
| `dhcp.option.dhcp == 2` | all Offers | 12 |
| `dhcp.option.dhcp_server_id` (as a column) | which server sent each Offer or ACK | 12 |
| `dhcp.option.router` (as a column) | the gateway each server hands out | 12 |
| `dhcp.option.dhcp == 6` | NAKs | 12 |

## DNS

| Filter | Shows | Scenario |
|------------------------------|----------------------------------|--------|
| `dns` | all DNS questions and answers | 15 |
| `dns.flags.response == 0 && !dns.response_in` | questions that never got an answer | 15 |
| `dns.time > 0.1` | answers that took longer than 100 ms | 15 |
| `dns.time` (as a column) | how long each answered question took | 15 |
| `dns.a` (as a column) | the address in each answer | 16 |
| `dns.resp.ttl` (as a column) | how long each answer may be cached | 16 |
| `dns.flags.authoritative == 1` | answers from a server that holds the record itself | 16 |
| `dns.flags.truncated == 1` | truncated answers | 17 |
| `dns or tcp.port == 53` | DNS over UDP and TCP together | 17 |
| `dns.rr.udp_payload_size` (as a column) | the UDP answer size each client accepts (EDNS) | 17 |
| `dns.flags.response == 0 && dns.count.add_rr == 0` | questions sent without EDNS (no OPT record) | 17 |
| `dns.count.answers > 10` | answers with many records | 17 |
| `dns.qry.name.len > 50` | DNS questions and answers with long names | 30 |
| `dns.qry.type == 16` | TXT questions and answers | 30 |
| `dns.flags.rcode == 3` | "No such name" answers | 30 |

## HTTP

| Filter | Shows | Scenario |
|------------------------------|----------------------------------|--------|
| `http.request` | every HTTP request | 2 |
| `http.time > 0.25` | replies that took longer than 250 ms (Wireshark displays milliseconds, but the filter value is in seconds) | 2 |
| `http` | one line per request and per complete reply | 4, 18, 22 |
| `http.time > 1` | replies that took more than a second (the value is in seconds) | 4, 18, 22 |
| `http.response.code >= 500` | server errors: 500, 502, 503, 504 | 18 |
| `http.server` (as a column) | which server software each response names | 18 |
| `http.time > 0.1` | HTTP responses slower than 100 ms | 26 |
| `http.time` (as a column) | the response time of every request | 26 |
| `http.response.code == 401` | rejected logins | 29 |
| `http.authbasic` | requests with basic-authentication credentials (add as a column) | 29 |

## TLS and certificates

| Filter | Shows | Scenario |
|------------------------------|----------------------------------|--------|
| `tls.alert_message` | TLS alerts | 19, 22 |
| `tls.alert_message.desc == 45` | Certificate Expired alerts | 19 |
| `tls.handshake.type == 11` | handshake messages that carry a certificate (readable in TLS 1.2) | 19, 21 |
| `tls.handshake.type == 1` | Client Hello messages | 19, 20 |
| `x509af.notAfter` | certificates, so you can add the expiry date as a column | 19 |
| `tls or tcp.flags.reset == 1` | the handshake and how it ended | 19 |
| `tls.handshake.extensions.supported_version` | Client Hellos that list their TLS versions | 20 |
| `tls.handshake.type == 1 && !tls.handshake.extensions.supported_version` | clients that can do TLS 1.2 at most | 20 |
| `tls.alert_message.desc == 70` | Protocol Version alerts | 20 |
| `tls.handshake.type == 2` | Server Hello messages (the version and cipher chosen) | 20 |
| `tls.handshake.extensions_server_name` | the server name each client asks for (add as a column) | 21 |
| `tls.handshake.type == 1 && !tls.handshake.extensions_server_name` | Client Hellos without SNI | 21 |
| `x509ce.dNSName` | the names in each certificate (add as a column) | 21 |
| `tls.alert_message.desc == 42` | Bad Certificate alerts | 21 |
| `tls.record.content_type == 23` | Application Data records (encrypted data) | 22 |

## SMB

| Filter | Shows | Scenario |
|------------------------------|----------------------------------|--------|
| `smb2` | all SMB2 requests and responses | 23 |
| `smb2.flags.response == 0` | requests only (count them) | 23 |
| `smb2.cmd == 5` | Create requests and responses (one pair per file opened) | 23 |
| `smb2.time > 0.03` | responses that took longer than 30 ms | 23 |

## Voice: SIP, SDP and RTP

| Filter | Shows | Scenario |
|------------------------------|----------------------------------|--------|
| `sip` | call signalling | 24 |
| `sdp` | SIP messages that carry an SDP | 24 |
| `sdp.connection_info.address` (as a column) | the address each side announces for its audio | 24 |
| `rtp` | the audio packets | 24, 25 |
| `rtp.seq` (as a column) | sequence numbers, to spot gaps and reordering | 25 |
| `sip or sdp` | the call signalling | 25 |

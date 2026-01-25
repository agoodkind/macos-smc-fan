# License and Legal Notice

## MIT License

Copyright (c) 2026 Alexander Goodkind <alex@goodkind.io>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Scope of This License

This license applies **only** to the original works created by the author:

- The **source code** in this repository (Swift, C, build scripts)
- The **documentation** and written analysis
- The **research methodology** and experimental procedures

This license does **not** grant any rights to Apple Inc. intellectual property. The following remain the property of Apple Inc. and are not licensed by this project:

- The SMC firmware, `thermalmonitord`, `AppleSMC.kext`, and other Apple binaries
- The underlying SMC hardware and protocols
- Any Apple trademarks, trade secrets, or proprietary implementations

The author makes no representation that use of the documented techniques is authorized by Apple or compliant with Apple's terms of service.

## Research Findings

The behavioral observations documented here (SMC key names, unlock sequences, timing parameters) represent independently discovered facts about system behavior obtained through lawful reverse engineering for interoperability purposes. These findings are not Apple intellectual property and may be freely used to create independent implementations.

## Interoperability

Independent implementations that achieve interoperability with Apple hardware based on the findings documented here are explicitly permitted, including:

- Reimplementing the documented SMC key sequences in your own code
- Using the discovered `Ftst` unlock mechanism in fan control software
- Applying the documented timing and retry logic
- Referencing this research in your project's documentation

No attribution is required, though it is appreciated.

## Research Purpose

This project constitutes independent security and systems research. The code and documentation result from analysis of publicly observable system behavior, runtime tracing (`dtrace`), and static analysis of compiled binaries using standard reverse engineering tools (IDA Pro). No Apple source code, leaked materials, or confidential documentation were used.

## Clean Room Considerations

The implementation follows clean room principles where feasible:

- **Specification-based**: SMC key schemas derive from prior published research, Linux kernel drivers, and independently documented behavior
- **Independent implementation**: Code was written based on observed behavior and documented specifications, not copied from decompiled output
- **No proprietary assets**: Repository contains no Apple binaries, private keys, certificates, trademarked materials, or anything directly derived from such (e.g., decompiled code, disassembly output)

However, this project involves analysis of Apple proprietary systems. Users should understand that:

- Binary analysis may violate Apple's End User License Agreement (EULA)
- The Digital Millennium Copyright Act (DMCA) restricts circumvention of access controls
- Distribution and use may carry legal risk depending on jurisdiction

## No Affiliation

This project is **not affiliated with, authorized by, endorsed by, or in any way officially connected with Apple Inc.** All product names, trademarks, and registered trademarks are property of their respective owners.

## Legal Counsel

If you have concerns about the legal implications of using this research or implementing fan control in your jurisdiction, consult a qualified attorney familiar with intellectual property and software law.

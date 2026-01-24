# License and Legal Notice

## Research Purpose

This project constitutes independent security and systems research. The code and documentation result from analysis of publicly observable system behavior, runtime tracing (`dtrace`), and static analysis of compiled binaries using standard reverse engineering tools (IDA Pro). No Apple source code, leaked materials, or confidential documentation were used.

## Clean Room Considerations

The implementation follows clean room principles where feasible:

- **Specification-based**: SMC key schemas derive from prior published research, Linux kernel drivers, and independently documented behavior
- **Independent implementation**: Code was written based on observed behavior and documented specifications, not copied from decompiled output
- **No proprietary assets**: Repository contains no Apple binaries, private keys, certificates, or trademarked materials

However, this project involves analysis of Apple proprietary systems. Users should understand that:

- Binary analysis may violate Apple's End User License Agreement (EULA)
- The Digital Millennium Copyright Act (DMCA) restricts circumvention of access controls
- Distribution and use may carry legal risk depending on jurisdiction

## No Affiliation

This project is **not affiliated with, authorized by, endorsed by, or in any way officially connected with Apple Inc.** All product names, trademarks, and registered trademarks are property of their respective owners.

## Disclaimer of Warranty

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Intended Use

This project is intended solely for:

- Educational study of systems architecture
- Security research and interoperability analysis
- Personal, non-commercial experimentation

Commercial use or integration into products is discouraged without independent legal review.

## Legal Counsel

If you intend to use, modify, or distribute this code beyond personal research, consult a qualified attorney familiar with intellectual property and software law in your jurisdiction.

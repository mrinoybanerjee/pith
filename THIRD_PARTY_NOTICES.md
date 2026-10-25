# Third-Party Notices

## Stats

Pith adapts parts of [Stats](https://github.com/exelban/stats) at tag `v3.0.22`
(commit `1282cd5`), under the MIT License. Each adapted file names its source in a
header comment.

| Pith file | Stats source at v3.0.22 | What |
|---|---|---|
| `SystemReader.swift` | `Modules/RAM/readers.swift` L37–L103 | `host_statistics64` and swap sysctl reads |
| `PressureMonitor.swift` | `Modules/RAM/readers.swift` L37–L103 | Pressure sysctl read |
| `SystemReader.swift` | `Modules/CPU/readers.swift` L42–L156 | `host_processor_info` per-core deltas with wrap-safe `UInt32` math |
| `AppGrouper.swift` | `Modules/RAM/readers.swift` L210–L227 | `responsibility_get_pid_responsible_for_pid` through `dlsym` |
| `ProcessTableSource.swift` | `Modules/Disk/readers.swift` L448–L457 | The `proc_pid_rusage` disk-I/O read pattern |

The three source files carry the header "Copyright © 2020 Serhiy Mytrovtsiy". The Stats
license at `v3.0.22` follows.

```text
MIT License

Copyright (c) 2019 Serhiy Mytrovtsiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

# server-to-client-fuzz

A libFuzzer target over everything a server sends a client after the handshake, and over the
Diffie-Hellman parameters of Apple Remote Desktop authentication: the kit's own readers and
decoders, under AddressSanitizer, guided by coverage.

It runs the same session as the seeded fuzz in the test suite
(`Tests/RoyalVNCKitTests/ServerToClientFuzzTests.swift`): a fuzz input is a framebuffer and a list
of rectangles and messages (`FuzzInput` in `ServerToClientFuzzer.swift`), laid out as a server sends
them and handed to the kit through a `ScriptedReader`, dispatched as `VNCConnection`'s receive loop
does, through the decoder table a `VNCConnection` builds, into a real `VNCFramebuffer`. The seeds
are the suite's generators and the regression tests' streams.

## Families

`FUZZ_FAMILY` picks what a run spends its time on. A family's rectangles keep to its encodings
whatever libFuzzer does to the bytes (each rectangle's encoding is the family's, picked by index).

| Family         | Rectangles                                                         | Other messages |
|----------------|--------------------------------------------------------------------|----------------|
| `raw-copyrect` | Raw, CopyRect                                                      | no             |
| `rre-corre`    | RRE, CoRRE                                                         | no             |
| `hextile`      | Hextile                                                            | no             |
| `zlib`         | zlib                                                               | no             |
| `zrle`         | ZRLE                                                               | no             |
| `tight`        | Tight                                                              | no             |
| `pseudo`       | DesktopSize, ExtendedDesktopSize, Cursor, DesktopName, LastRect, Raw | no           |
| `messages`     | all of the above, and unknown encodings                            | SetColourMapEntries, ServerCutText, Bell, EndOfContinuousUpdates, unknown |
| `ard`          | -- the input is the parameters themselves: generator, key size, prime, public value | -- |

## Build

Linux, with a Swift toolchain that has libFuzzer -- the `swift:6.2` image does -- from the
package's root:

    ./Tools/fuzz/build.sh

It builds the kit and its dependencies instrumented (`-sanitize=fuzzer,address -enable-testing`)
into `.build-fuzz`, archives them, and links the harness with `swiftc -parse-as-library`, since
libFuzzer brings its own `main`. `CONFIG=debug` builds the debug configuration; the default,
`release`, is the build people run, and some of what the fuzzing found was guarded in debug builds
only.

In a container, the sources from `git archive`:

    docker run -d --name fuzz swift:6.2 sleep infinity
    docker exec fuzz mkdir -p /src
    git archive HEAD | docker exec -i fuzz tar -x -C /src
    docker exec -w /src fuzz ./Tools/fuzz/build.sh

and the commands below likewise, each a `docker exec -w /src fuzz ...` (with `-e FUZZ_FAMILY=...`).

## Run

Seeds, then a run of ten minutes:

    FUZZ_FAMILY=hextile FUZZ_WRITE_SEEDS=seeds/hextile .build-fuzz/out/server-to-client-fuzz
    mkdir -p corpus/hextile artifacts/hextile
    FUZZ_FAMILY=hextile .build-fuzz/out/server-to-client-fuzz \
        -max_total_time=600 -timeout=10 -rss_limit_mb=3072 -use_value_profile=1 \
        -dict=Tools/fuzz/server-to-client.dict -artifact_prefix=artifacts/hextile/ \
        corpus/hextile seeds/hextile

- `-timeout=10`: an input still running after ten seconds is reported as a hang.
- `-rss_limit_mb=3072`: the process's resident size, and any one allocation, past 3 GiB is reported.
  A session makes framebuffers of at most a million pixels (`FuzzSession.allocationBudget`); the
  kit's own ceiling is 2^28 (`VNCFramebuffer.maximumPixelCount`).
- At exit the run prints what each decoder and message type was fed, how many bytes the kit read
  for them, and how each ended (`FuzzTally`); the `ard` family, how each set of parameters ended.

## A crash

libFuzzer writes the input to `artifacts/<family>/crash-...`. Replay it:

    FUZZ_FAMILY=hextile .build-fuzz/out/server-to-client-fuzz artifacts/hextile/crash-...

and shrink it with `-minimize_crash=1 -runs=100000`. The bytes are a `FuzzInput` in the layout
`FuzzInput.init(fuzzBytes:family:)` reads; a regression test belongs in `FuzzFindingTests`, as the
smallest stream that shows the fault.

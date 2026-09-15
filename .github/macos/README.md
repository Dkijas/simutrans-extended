# Signing and notarizing the Simutrans-Extended macOS build

macOS refuses to run a downloaded application that is not signed with a
Developer ID **and** notarized by Apple, except through a right-click and an
explicit override. Until now the macOS nightly was signed **ad hoc** — a
signature with no identity behind it, which Gatekeeper treats as no signature
at all.

This directory holds the scripts, and `../workflows/macos-sign-notarize.yml`
the workflow, that build the macOS packages, sign them with a real Developer
ID, send them to Apple, staple the resulting ticket and attach them to the
`Nightly` release. It runs unattended, once a night, and it publishes only
what came out the other end intact.

> **Nothing here is a substitute for reading what it costs.** Every commit the
> nightly selects is signed with a real Developer ID without anyone looking at
> it first. Apple can revoke a Developer ID, and the account with it. The
> header comment of `macos-sign-notarize.yml` sets out what is and is not
> checked before that happens.

---

## What changes for people downloading the game

| | before | after |
| --- | --- | --- |
| `macos.zip` | SDL3, arm64, ad-hoc signed | SDL3, arm64, Developer ID, notarized, stapled |
| `macos-sdl2.zip` | SDL2, arm64, ad-hoc signed | SDL2, arm64, Developer ID, notarized, stapled |
| `macos-intel.zip` | — | SDL3, x86_64 (new) |
| `macos-sdl2-intel.zip` | — | SDL2, x86_64 (new) |
| `macos-signed.txt` | — | what was published, with hashes (new) |
| contents | four bare Unix executables plus `lib/` | `simutrans-extended.app` plus the game data |
| game data | none at all | `config/`, `font/`, `text/`, `themes/`, `script/`, `music/`, `get_pak.sh` |
| minimum macOS | 26.0 | measured per build and stated in `macos-signed.txt` |

The two existing names keep exactly the meaning they had, so every link people
already have keeps working and starts resolving to a signed file. Intel is new
and gets new names rather than changing what an existing name means.

### The application bundle, and where the data goes

`simmain.cc` takes the directory of `argv[0]`, and when it ends in
`.app/Contents/MacOS/` it strips that and chdir()s to the directory that
**contains** the application. So the data is a **sibling** of the `.app`, not
a folder inside it, and the archive unpacks to:

```
simutrans/
    simutrans-extended.app
    config/  font/  text/  themes/  script/  music/  get_pak.sh
    simutrans-extended-server   makeobj-extended   nettool-extended
    README-macOS.txt
```

Keep them together. Put a pakset in that same folder. Saved games and settings
go to `~/Library/Simutrans`, as they always have.

This is the opposite of Simutrans Standard, which installs its data at
`Contents/Resources/simutrans` **inside** the bundle. Copying Standard's
layout here would produce a bundle that starts and then cannot find anything.

### The three command-line tools

The real `simutrans-extended-server`, `makeobj-extended` and
`nettool-extended` binaries live **inside** the bundle, in
`Contents/MacOS/`. That is not tidiness: only the bundle gets signed, stapled
and assessed, so a binary outside it would ship as unsigned, unstapled code —
which is the problem this whole arrangement exists to fix.

The three names at the top level are small scripts that `exec` the real
binary by its full path. That path is what makes the server's data directory
resolve, by the same rule as above. They can also be run directly:

```sh
"simutrans-extended.app/Contents/MacOS/makeobj-extended" ...
```

`check-payload.sh` enforces the rule that makes this safe: in
`allow-data-siblings` mode, **no Mach-O file may exist outside the bundle**.

---

## What a maintainer has to do once

### 1. Apple Developer Program

A paid membership ($99/year). A Developer ID Application certificate can only
be issued under one, and only by an Account Holder or Admin.

Export the certificate **with its private key** from Keychain Access as a
`.p12` with a strong password.

### 2. App Store Connect API key for notarization

*App Store Connect → Users and Access → Integrations → App Store Connect API.*

**It must be a Team key with the Developer role.** An Individual key cannot be
used with `notarytool`; this is easy to get wrong and costs a whole rehearsal.

The `.p8` is downloadable **once**. Note the Key ID and the Issuer ID.

### 3. The GitHub environment

Create an environment named **`macos-signing`** in *Settings → Environments*.

**Do not set required reviewers.** A job that references an environment must
satisfy its protection rules before it can read that environment's secrets —
which is exactly what gates the signing identity — but a required reviewer
means every night waits for a human and nothing is ever published. Removing
that gate is the deliberate cost of automatic signing.

What to set instead:

* **Deployment branch policy: selected branches → `master`.** This is the
  second enforcement of "master only"; the first is that the workflow is only
  ever called by the nightly.
* **A wait timer** (say 10 minutes) if you want a window in which a run can be
  cancelled before the identity is used. It is the only thing standing between
  a bad commit and a signature, and it is a setting, not code. It does cost
  that much delay every night.

> If the environment does not exist, GitHub creates it on first use **without
> any protection rule and without any secret**. The workflow then fails at its
> first step with a message naming what is missing. It will never fall back to
> an ad-hoc signature or hand back an unsigned package.

#### Secrets

| Secret | What it is | Consumed by |
| --- | --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64 of the Developer ID Application `.p12` | `keychain.sh` |
| `MACOS_CERTIFICATE_P12_PASSWORD` | The password that `.p12` is encrypted with | `keychain.sh` |
| `MACOS_NOTARY_API_KEY_P8` | Base64 of the App Store Connect API key `.p8` | `notarize.sh`, `notary-status.sh` |
| `MACOS_NOTARY_API_KEY_ID` | The key ID, e.g. `T9GPZ92M7K` | `notarize.sh`, `notary-status.sh` |
| `MACOS_NOTARY_API_ISSUER_ID` | The issuer UUID | `notarize.sh`, `notary-status.sh` |
| `MACOS_ARTIFACT_KEY` | Passphrase for the encrypted retention container | `preserve-artifact.sh`, `restore-artifact.sh`, `bind-submission.sh` |

`MACOS_ARTIFACT_KEY` is optional for a manual run with `retention=none`. **The
nightly path always uses `retention=required`**, so for the nightly it is not
optional: without it the run stops before the signing identity is ever loaded.

#### Variables

Not secret. They are variables so that the workflow can check that the
certificate it was handed is the one the project expects.

| Variable | What it is | Consumed by |
| --- | --- | --- |
| `MACOS_SIGNING_IDENTITY` | The exact identity string, e.g. `Developer ID Application: Example (AB12CD34EF)` | `keychain.sh`, `sign.sh`, and recorded in the published `.txt` |
| `MACOS_TEAM_ID` | The 10-character Team ID, e.g. `AB12CD34EF` | `sign.sh` asserts the signature carries it |

#### Permissions the jobs need

| Job | `contents` | `actions` | environment |
| --- | --- | --- | --- |
| `resolve` | read | read | — |
| `build-tools` | read | — | — |
| `build-game` | read | read | — |
| `sign` | read | read | **`macos-signing`** |
| `publish` | **write** | — | — none, on purpose |

`publish` deliberately does **not** reference the environment. That is what
makes it unable to read a signing secret: it only moves files that were
already signed elsewhere. The consequence is that it cannot read
`MACOS_SIGNING_IDENTITY` either, which is why the identity travels beside each
archive in its `.meta` file rather than being read there.

The calling job in `nightly.yml` must grant `contents: write` and
`actions: read`, because a called workflow's permissions are capped by the
caller's.

#### Producing the base64 values

On a Mac, in a terminal, without writing the value to a file:

```sh
base64 -i DeveloperID.p12        | pbcopy   # -> MACOS_CERTIFICATE_P12
base64 -i AuthKey_T9GPZ92M7K.p8  | pbcopy   # -> MACOS_NOTARY_API_KEY_P8
```

Then paste straight into the GitHub secret field and clear the clipboard.

**Base64 is an encoding, not encryption.** Anyone who obtains the value has
the file. The `.p12` is additionally protected by its own password; the `.p8`
is not protected by anything, which is why it lives in a secret and is written
to disk only inside a run, with `umask 077`, and deleted afterwards.

Never commit a `.p12`, `.p8`, `.cer`, `.key` or any password to this
repository — including "just for a test". This repository is public, and a
Developer ID private key that lands in it has to be treated as compromised and
revoked.

---

## How it fits together

```
nightly.yml
  check-updates      picks the head of the last SUCCESSFUL ci.yml run on
                     master, creates/updates the Nightly release, moves the
                     Nightly tag to that commit
        |
        +-- deploy-bin      linux + windows, from ci.yml artifacts (unchanged)
        +-- update-paks     pakset deployment (unchanged)
        +-- sign-macos  ->  macos-sign-notarize.yml
        |                      resolve       checks the commit AND the CI run
        |                      build-tools   server, makeobj, nettool  (x2)
        |                      build-game    game + bundle assembly    (x4)
        |                      sign          Developer ID + notarize   (x4)
        |                      publish       attaches the four archives
        +-- deploy-package  simutrans-extended.zip (unchanged, and NOT waiting
                            on sign-macos)
```

### Two run identities, never confused

* **`ci_run_id`** — the CI run whose success made the commit eligible. It is
  the authority for **which commit**, and nothing else. `resolve` checks it
  against the API: same repository, `ci.yml`, branch `master`, conclusion
  `success`, and `head_sha` equal to the commit being signed.
* **`github.run_id`** — this run. It is the source of the **bytes**. Every
  artifact the signing job consumes was produced by a job of this same run and
  is resolved by artifact **id**, not by name.

No check compares one against the other.

### Why the macOS packages are built here and not taken from CI

The unsigned nightly took them from `ci.yml`. That cannot work for a signed
package, for three measured reasons:

* `ci.yml` runs its macOS jobs on `macos-latest`, an arm64 image. **There is
  no x86_64 macOS build of Extended in CI at all**, so half of what has to be
  signed does not exist there.
* Nothing in `ci.yml` pins `CMAKE_OSX_DEPLOYMENT_TARGET`, so every Mach-O in
  the published `macos.zip` declares a minimum of **macOS 26.0** — measured on
  the bytes of the 2026-09-14 nightly, not inferred from the runner label.
* CI uploads the bare executable and never the install tree, and an
  application bundle needs the data that goes beside it.

The **policy** the nightly owns — which commit is fit to publish — is
untouched. Only the production of the macOS bytes moved.

### Version identity

There is no SVN revision and no `git-svn-id` here; the commit **is** the
revision. `resolve` computes `git rev-parse --short=9`, which is the form the
release title already uses (`Nightly #cc56217cf`), and
`SimutransCommitInfo.cmake` compiles `REVISION=<short 7>` into the executable.

That last part has a trap worth knowing: `SimutransCommitInfo.cmake` calls
`git rev-parse` **without `WORKING_DIRECTORY`**, so it reads cmake's process
directory. Both build jobs therefore run cmake from inside the checkout and
then **assert** that the commit cmake reported is the one that was asked for.
Without that, a build configured from the workspace root would be stamped with
whatever repository happened to be there, or with nothing.

---

## The scripts

| Script | What it does |
| --- | --- |
| `make-bundle.sh` | assembles `simutrans-extended.app`, bundles the dylibs, writes `Info.plist`, the wrappers and the README |
| `inspect-bundle.sh` | inventories the Mach-O files, checks the architecture and measures the effective minimum macOS |
| `resolve-artifact.sh` | resolves an artifact name to exactly **one** artifact id, checking run and repository |
| `verify-provenance.sh` | compares a downloaded artifact's provenance record against what the job already knows |
| `check-payload.sh` | runs **before** the identity is loaded: symlinks, containment, setuid, one bundle, no code outside it |
| `keychain.sh` | creates and destroys the temporary keychain the identity lives in |
| `sign.sh` | signs every Mach-O from the inside out, then proves the result is fit to submit |
| `preserve-artifact.sh` | encrypts and stores the exact archive that is about to be submitted |
| `notarize.sh` | submits to Apple, waits, staples |
| `bind-submission.sh` | ties the preserved archive to the submission UUID |
| `notary-status.sh` | asks Apple about a submission, read-only |
| `restore-artifact.sh` | recovers a preserved archive and proves it is the one meant |
| `verify-binding.sh` | checks a binding record against a container |
| `collect-publish-set.sh` | decides whether the signed archives are fit to publish, and lays them out under the public names |
| `artifact-lib.sh`, `notary-lib.sh` | shared implementation |

Most of these come from Simutrans Standard's trunk at **r12269** and are
unchanged apart from names. What is new or changed for Extended:

* `make-bundle.sh` — new; Extended has no `MACOSX_BUNDLE` in CMake at all.
* `resolve-artifact.sh`, `verify-provenance.sh` — new; Standard did the same
  work inline in YAML. Extended needs it in three places, and having it in a
  script is what makes it testable.
* `collect-publish-set.sh` — new; four variants instead of two, and a backend
  that has to be checked as well as an architecture.
* `check-payload.sh` — gained the `allow-data-siblings` mode described above.
  With no third argument its behaviour is Standard's, unchanged.

### Decisions worth knowing about

**No `--deep` signing.** `codesign --deep` applies one set of flags to
whatever it finds and silently skips what it does not recognise; Apple
documents it as unsuitable for distribution. Every Mach-O is signed by name,
deepest first. `--deep --strict` **is** used for verification, which is what
Apple recommends.

**No entitlements.** Re-measured on Extended rather than inherited: at
`cc56217cf` the tree contains no `dlopen`, `dlsym` or `dlclose` at all — zero
occurrences, the vendored `squirrel/` included — no `mprotect`, `PROT_EXEC` or
`MAP_JIT`, and no `AVCaptureDevice`, `AVAudioRecorder` or `CLLocationManager`.
macOS audio is `AVAudioPlayer`, which is playback only. An empty entitlement
set is the minimum that works; adding entitlements "just in case" weakens the
Hardened Runtime.

**Runner images are pinned** to `macos-15` and `macos-15-intel`, both free and
unlimited on public repositories. No larger runner label appears anywhere, so
this cannot incur a charge. They are pinned rather than `macos-latest` because
the minimum macOS of the product is set by the SDK and the Homebrew bottles,
and following `macos-latest` is exactly how the unsigned nightly ended up
requiring macOS 26.0 without anyone deciding it. GitHub still updates the
contents of a pinned image, so the floor is **measured** after every build and
carried into `macos-signed.txt`, never asserted.

**`removeArtifacts` is now `false`.** It used to delete every asset on the
release so each job could put its own back. For a job that always succeeds
that is the same as overwriting; for one that can fail — and Apple's notary
service can reject or stall for reasons that have nothing to do with this
project — it turns "no new build today" into "no build at all". Every
publisher already replaces its own asset by name. The one thing
`removeArtifacts` did that overwriting does not is clear away names no longer
produced, and a step in `check-updates` now does that from an explicit list.

**All four macOS variants publish, or none do.** Publishing the two that did
build would leave the other two names holding the previous night's archives
while `macos-signed.txt` described this night's — four files that no longer
agree. `collect-publish-set.sh` refuses, and the previous set stays intact.

**Staleness is measured against the `Nightly` tag, not master's tip.**
Standard compares against the tip because that is what it publishes. Extended
deliberately publishes the head of the last *successful* CI run, which is
frequently not the tip, so that comparison would fail every night that the
newest commit is still building. `check-updates` moves the tag before any of
this starts, so a tag that has moved on is proof that this run is the stale
one. It catches a concurrent nightly, a hand re-run of an old run, and a run
that sat waiting on the notary service.

---

## Surviving a verdict that arrives too late

The archive is preserved **before** it is submitted. In Standard, on
2026-09-08, a bundle was signed and submitted, the run ended before Apple
answered, and the signed bytes went with the runner — so a later acceptance
had nothing left to staple.

One submission per file, its UUID recorded, and one container per **variant**
(`<arch>-<backend>`), because Extended has four where Standard had two.

`macos-notarize-resume.yml` finishes such a submission: it asks Apple about
that same UUID, recovers the container, proves it is the one meant, and
staples. It never re-submits and never re-signs.

**What it produces is a stapled `simutrans-extended.app`, not a publishable
`macos.zip`** — the preserved container holds only what was submitted, and
Apple has no opinion about `config/` or the paksets. To replace a night's
download, either re-run the failed jobs of the signing run (which reuses the
artifacts that did succeed) or wait for the next nightly.

`macos-notary-status.yml` asks Apple about a submission without touching
anything.

### Re-running failed jobs works, and that is not an accident

The provenance gate bounds `run_attempt` rather than pinning it. Standard
pinned it, and on 2026-09-09 that made GitHub's *only* repair impossible: the
artifact that had survived honestly reported attempt 1 while the retry was
attempt 2, and the gate refused it. A provenance gate must fix **what**
produced the work — the artifact, the commit, the repository — not **how** it
was scheduled.

### Why the container is encrypted

A workflow artifact in a public repository is not private: GitHub requires
"read access to the repository" to download one, and on a public repository
everyone has that. So what is stored is ciphertext — OpenPGP, AES-256 in OCB,
an AEAD mode from RFC 7253, produced by the GnuPG already on the runner, and
inspected afterwards and rejected if it is not that. `artifact-lib.sh` carries
the specification.

No `.p12`, no `.p8`, no password and no keychain is ever in the container.

---

## Turning it off

*Actions → "macOS signed build (Developer ID)" → … → **Disable workflow***.
The nightly's call then fails and the rest of the nightly continues; previous
macOS downloads stay exactly where they are, and no certificate has to be
revoked.

A softer option: put a required reviewer back on the `macos-signing`
environment. Signing then waits for a human every night rather than stopping.

---

## One warning before you push a branch here

`ci.yml` runs on **every push to every branch**, and its first job runs
`./cleanup_code.sh` and then **commits the result to your branch** through
`stefanzweifel/git-auto-commit-action` with `contents: write`.

`cleanup_code.sh` only rewrites `*.h` and `*.cc`, so a branch that touches
only `.github/` is not rewritten — but the job still runs, and if it ever does
find something your branch tip moves under you. Check the branch head after
pushing.

The signing workflow itself never runs on a push and never on a pull request.

---

## What has been validated, and what has not

Validated without a Mac and without an Apple account:

* `actionlint` clean on all four workflows; `shellcheck -S style` clean on all
  17 scripts.
* 66 directed tests covering the provenance gate, the artifact selector, the
  payload check, the publish set, the staleness gate and the asset-name
  mapping — including an arm64 build offered under the Intel name, an SDL2
  build offered under the SDL3 name, an ambiguous artifact, an artifact from
  another run or repository, and recovery from an earlier attempt.

**Not validated, and it needs a macOS runner or a Mac:** the build itself, the
bundle assembly, the dylib rewriting, signing, notarization, stapling,
Gatekeeper assessment, and whether the `.app` starts from Finder. None of
those have been exercised, and no claim is made about them here.

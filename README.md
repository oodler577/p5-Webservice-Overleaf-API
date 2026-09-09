# Webservice::Overleaf::API

`Webservice::Overleaf::API` is a Perl client for useful Overleaf integration
surfaces. The distribution also installs the `overleaf` command-line client.

The project deliberately distinguishes two kinds of integration:

* **Documented Overleaf interfaces**: Open in Overleaf and the Git bridge.
* **Experimental browser-session interfaces**: project listing, project ZIP
  download, remote compilation, PDF download, and compilation artifacts.

The experimental operations use observable Overleaf web-application behavior
rather than a documented stable public API, so they require explicit opt-in in
the Perl API (`experimental => 1`) and in the CLI (`--experimental`).

## Science Perl context

This is general-purpose Overleaf tooling, but it grew in part from practical
Git/LaTeX work used while helping authors and editors prepare material for the
**Science Perl Journal**. The author, Brett Estrade (OODLER), is a member of the
Perl Community's **Science Perl Committee** and a Co-Editor of the Journal.

The tool is not required for Journal submissions; it is simply one convenient
way to work. If you are doing scientific, engineering, or other technical work
with Perl, you are welcome to learn more about the [Science Perl
Committee](https://perlcommunity.org/science/). The [Science Perl
Journal](https://science.perlcommunity.org/spj) can be read online, and its
[submission information](https://science.perlcommunity.org/spj/about/submissions)
is available for anyone considering an article. Readers interested in printed
issues can follow the Journal's
[announcements](https://science.perlcommunity.org/spj/announcement) for current
availability.

## Installation

From CPAN:

```sh
cpanm Webservice::Overleaf::API
```

The distribution declares the SSL/TLS modules required by `HTTP::Tiny`, so a
normal CPAN/cpanm installation also pulls in the Perl-side HTTPS stack used to
communicate with Overleaf.

Check the installed client:

```sh
overleaf --version
overleaf --help
```

For development from a checkout:

```sh
cpanm Dist::Zilla
dzil authordeps --missing | cpanm --notest
dzil listdeps --missing | cpanm --notest
dzil test
dzil build
```

Dist::Zilla is part of the local/release workflow; GitHub CI intentionally runs
the tests directly and does not invoke `dzil`.

## Perl API quick start

The documented import and Git URL helpers do not require a browser session:

```perl
use Webservice::Overleaf::API;

my $ol = Webservice::Overleaf::API->new;

my $url = $ol->open_uri(
    uri           => 'https://example.org/paper.zip',
    engine        => 'lualatex',
    main_document => 'main.tex',
);

say $ol->project_url('PROJECT_ID');
say $ol->git_url('PROJECT_ID');
```

Experimental project and compilation operations require an authenticated
browser session:

```perl
use Webservice::Overleaf::API;

my $ol = Webservice::Overleaf::API->new(
    experimental => 1,
    session      => $ENV{OVERLEAF_SESSION},
);

for my $project ($ol->projects->all) {
    say join "\t", $project->id, $project->name;
}

my $compile = $ol->compile('PROJECT_ID');

$ol->download_pdf(
    'PROJECT_ID',
    compile => $compile,
    to      => 'paper.pdf',
);

$ol->download_output(
    $compile,
    'output.log',
    to => 'output.log',
);
```

## CLI: start-to-finish practical workflow

### Local Git checkout -> Overleaf -> PDF

The most useful 0.06 workflow treats the **Git checkout as the local working
copy**, the browser-session interface as the **remote compiler/output
interface**, and the ZIP as an **exported snapshot**.

After cloning an Overleaf project through the Git bridge:

```sh
overleaf clone "$ID" my-paper
cd my-paper
```

edit and commit the project normally:

```sh
$EDITOR main.tex
git add .
git commit -m 'revise paper'
```

Then one command can synchronize the committed project, compile it on
Overleaf, and download the PDF:

```sh
overleaf --experimental \
  --session-file ~/.ol-session.txt \
  compile main.tex
```

Typical concise output is:

```text
project  0123456789abcdef
remote   origin
root     main.tex
source   committed HEAD
push     ok
status   success
saved    main.pdf
```

The command discovers the project ID from the Overleaf Git remote and pushes
**the complete committed project** to the remote `master` branch. It does not
try to guess whether only `.tex`, `.bib`, images, styles, classes, or some other
file type is needed. A TeX project is the compilation unit.

A dirty work tree is rejected. The client will not silently `git add`, create a
commit, or leave files out of the build. Commit or stash your changes first.
The selected root document must also be tracked by Git. If Overleaf has newer
web-editor changes and the push is rejected as non-fast-forward, pull and
reconcile those changes normally; the client deliberately does not modify your
local history for you.

If you deliberately want to compile the project state already on Overleaf:

```sh
overleaf --experimental \
  --session-file ~/.ol-session.txt \
  --no-push \
  compile main.tex
```

Omit the root filename to use the document configured on Overleaf:

```sh
overleaf --experimental \
  --session-file ~/.ol-session.txt \
  compile
```

Use `--output` to choose the PDF name:

```sh
overleaf --experimental \
  --session-file ~/.ol-session.txt \
  --output reviewed-draft.pdf \
  compile main.tex
```

View the downloaded PDF on Linux:

```sh
xdg-open main.pdf >/dev/null 2>&1 &
```

or from MSYS2/Git Bash on Windows:

```sh
start main.pdf
```

The lower-level form remains available when you want to compile whatever is
already on Overleaf without using a local Git checkout:

```sh
overleaf --experimental \
  --session-file "$SESSION" \
  compile "$ID"
```

That form prints the compile status, PDF URL, and build-artifact list; use the
`pdf` command to download its PDF separately.

The following sequence is intended to be usable as a real working session.

### 1. Get the Overleaf browser session

Log into `https://www.overleaf.com/` in your normal browser.

**Firefox**

1. Press `F12`.
2. Open **Storage**.
3. Open **Cookies** and select `https://www.overleaf.com`.
4. Find `overleaf_session2`.
5. Copy only its **Value**.

**Chrome / Edge / Chromium**

1. Press `F12`.
2. Open **Application**.
3. Under **Storage**, open **Cookies**.
4. Select `https://www.overleaf.com`.
5. Find `overleaf_session2` and copy only its **Value**.

Create a session file containing only that value:

```sh
printf '%s\n' 'PASTE_COOKIE_VALUE_HERE' > ~/.ol-session.txt
chmod 600 ~/.ol-session.txt
```

Do **not** put this in the file:

```text
overleaf_session2=...
```

The file is one line containing only the cookie value.

For subsequent commands:

```sh
SESSION=~/.ol-session.txt
```

Overleaf's Cookie Policy currently documents a **5-day retention period** for
`overleaf_session2`. Treat that as an approximate lifetime: logout, rotation,
revocation, or server-side invalidation can end a particular session sooner.
When commands begin failing authentication, copy a fresh cookie value from the
browser.

### 2. Validate authentication

```sh
overleaf --experimental \
  --session-file "$SESSION" \
  bootstrap
```

Expected:

```text
authenticated
```

### 3. List projects

```sh
overleaf --experimental \
  --session-file "$SESSION" \
  projects
```

Output is tab-separated:

```text
PROJECT_ID    PROJECT NAME    LAST_UPDATED
```

Choose one:

```sh
ID=0123456789abcdef
```

Useful non-session URL helpers:

```sh
overleaf project-url "$ID"
overleaf git-url "$ID"
```

### 4. Download and inspect the project source

Download the project ZIP:

```sh
overleaf --experimental \
  --session-file "$SESSION" \
  --output project.zip \
  zip "$ID"
```

Inspect everything:

```sh
unzip -l project.zip
```

Find TeX source files:

```sh
unzip -l project.zip | grep -Ei '\.tex$'
```

Extract the full tree:

```sh
mkdir project-src
cd project-src
unzip ../project.zip
find . -type f -name '*.tex' -print
cd ..
```

This is an important distinction:

* `zip` retrieves the **project/source tree**.
* `compile` reports **generated build artifacts**.

If `compile | grep tex` only shows names such as `output.chktex`,
`output.fdb_latexmk`, or `output.synctex.gz`, that is expected; those are build
products, not source `.tex` files.

### 5. Compile on Overleaf

Compile using the root document currently configured by Overleaf:

```sh
overleaf --experimental \
  --session-file "$SESSION" \
  compile "$ID"
```

Typical beginning of the output:

```text
status  success
pdf     https://www.overleaf.com/project/.../output/output.pdf?...
```

It then lists generated files such as:

```text
output  output.aux       aux       ...
output  output.bbl       bbl       ...
output  output.chktex    chktex    ...
output  output.log       log       ...
output  output.pdf       pdf       ...
output  output.stderr    stderr    ...
output  output.stdout    stdout    ...
```

A project using `minted` may produce many `_minted-output/*.pygtex` and
`*.pygstyle` entries. That is normal.

### 6. Find the root TeX document

Retrieve the compilation log:

```sh
overleaf --experimental \
  --session-file "$SESSION" \
  --output output.log \
  output "$ID" output.log
```

The log normally begins with a line like:

```text
**user_guide.tex
```

Extract just that first root-document line:

```sh
grep -m1 '^\*\*[^*]' output.log
```

Set the filename:

```sh
ROOT_TEX=user_guide.tex
```

### 7. Compile an explicit root

```sh
overleaf --experimental \
  --session-file "$SESSION" \
  --resource-path "$ROOT_TEX" \
  compile "$ID"
```

This is especially useful for projects containing more than one compilable TeX
document.

### 8. Download and view the PDF

```sh
overleaf --experimental \
  --session-file "$SESSION" \
  --resource-path "$ROOT_TEX" \
  --output document.pdf \
  pdf "$ID"
```

Check the result:

```sh
file document.pdf
ls -lh document.pdf
```

On Linux:

```sh
xdg-open document.pdf >/dev/null 2>&1 &
```

On Windows from MSYS2 or Git Bash:

```sh
start document.pdf
```

If an explicit Windows path is needed:

```sh
cmd.exe /c start "" "$(cygpath -w document.pdf)"
```

### 9. Retrieve useful build artifacts

The `output` command performs a compile and downloads one reported artifact:

```sh
overleaf --experimental \
  --session-file "$SESSION" \
  --output document.log \
  output "$ID" output.log

overleaf --experimental \
  --session-file "$SESSION" \
  --output document.bbl \
  output "$ID" output.bbl

overleaf --experimental \
  --session-file "$SESSION" \
  --output document.chktex \
  output "$ID" output.chktex
```

Then ordinary shell tools work well:

```sh
tail -100 document.log
cat document.bbl
cat document.chktex
```

Only artifacts returned by the Overleaf compile can be downloaded this way.

## Git integration

The Git bridge is separate from the browser-session interface. It does not use
`~/.ol-session.txt`.

Overleaf's Git integration uses token-based Git authentication and is currently
a premium feature on Overleaf Cloud. Let Git handle and store the credential
rather than embedding it in URLs.

Print the Git URL:

```sh
overleaf git-url "$ID"
```

Clone:

```sh
overleaf clone "$ID" my-paper
```

Inspect:

```sh
cd my-paper
git status
git remote -v
git log --oneline -10
cd ..
```

Pull edits made through the Overleaf web editor:

```sh
overleaf pull my-paper
```

After making and committing local changes:

```sh
cd my-paper
git add .
git commit -m 'update paper'
cd ..
```

For a clone whose current branch tracks the Overleaf remote:

```sh
overleaf push my-paper
```

`push` changes the Overleaf project, so inspect `git status` and your commits
first.

### Add an Overleaf remote to an existing repository

```sh
cd existing-paper
overleaf remote-add . "$ID" overleaf
git remote -v
```

Overleaf's Git bridge is not a full general-purpose Git server. It presents one
linear project history and the remote branch is currently named `master`.
Overleaf's documented setup for an unrelated existing repository includes
reconciling the histories before the first push. Once prepared, an explicit
push is typically:

```sh
git push overleaf master --set-upstream
```

A differently named local branch can be mapped to Overleaf's branch:

```sh
git push overleaf my-branch:master
```

The Git bridge creates commits as needed when Git fetch/pull/push operations
translate between Overleaf's internal History system and Git.

## Open in Overleaf

Generate an Open in Overleaf URL from a remotely hosted TeX or ZIP file:

```sh
overleaf open-uri \
  --engine lualatex \
  --main-document main.tex \
  https://example.org/project.zip
```

Generate an import URL from a local TeX file:

```sh
overleaf open-data paper.tex
```

Generate a complete HTML POST form containing a TeX snippet:

```sh
overleaf snippet-form paper.tex
```

## Authentication summary

There are two credentials, used for two different integration surfaces:

| Operation | Credential |
| --- | --- |
| `projects`, `bootstrap`, `zip`, `compile`, `pdf`, `output` | `overleaf_session2` browser session |
| `clone`, `pull`, `push`, Git remote access | Overleaf Git authentication token |
| `project-url`, `git-url`, `open-uri`, `open-data`, `snippet-form` | none required by the client |

The browser cookie is a credential: do not commit it, print it in logs, include
it in bug reports, or put it directly on a command line when a session file or
environment variable will do.

## Testing and CI

The test suite is network-hermetic. HTTP traffic and Git operations are mocked
where external access would otherwise be required.

GitHub Actions currently tests Perl 5.10, 5.20, 5.30, 5.40, and 5.44.

## Documentation

Full module documentation:

```sh
perldoc Webservice::Overleaf::API
```

Full CLI documentation:

```sh
overleaf --help
```

## License

Same terms as Perl itself.

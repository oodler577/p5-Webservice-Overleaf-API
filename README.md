# Webservice::Overleaf::API

A Perl client for Overleaf integration surfaces.

The distribution deliberately separates:

* **Official/supported interfaces** — Overleaf's **Open in Overleaf** import interface and Git bridge.
* **Experimental interfaces** — browser-session project listing, project ZIP download, remote compilation, PDF download, and compile artifacts. These use undocumented Overleaf web-application endpoints and require `experimental => 1`.

```perl
use Webservice::Overleaf::API;

my $ol = Webservice::Overleaf::API->new;

my $url = $ol->open_uri(
    uri           => 'https://example.org/paper.zip',
    engine        => 'lualatex',
    main_document => 'main.tex',
);

say $ol->git_url('PROJECT_ID');
```

Experimental use:

```perl
my $ol = Webservice::Overleaf::API->new(
    experimental => 1,
    session      => $ENV{OVERLEAF_SESSION},
);

for my $project ($ol->projects->all) {
    say $project->name;
}

my $compile = $ol->compile('PROJECT_ID');
$ol->download_pdf('PROJECT_ID', compile => $compile, to => 'paper.pdf');
$ol->download_output($compile, 'output.log', to => 'output.log');
```

`OVERLEAF_SESSION` is a browser authentication credential. Treat it like a password: do not commit it, print it, or put it in command-line arguments.

## Development

```sh
cpanm Dist::Zilla
dzil authordeps --missing | cpanm --notest
dzil listdeps --missing | cpanm --notest
dzil test
dzil build
```

All tests use injected mock transports/runners and make no live Overleaf requests.

## License

Same terms as Perl itself.

## Testing and CI

The test suite is network-hermetic: Overleaf HTTP traffic and Git operations are
mocked where external access would otherwise be required. GitHub Actions tests
Perl 5.10, 5.20, 5.30, 5.40, and 5.44, runs a Dist::Zilla author build, and has
a dedicated Devel::Cover gate requiring complete statement, branch, condition,
subroutine, and POD coverage for `lib/Webservice/Overleaf/API.pm`.

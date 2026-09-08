use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use File::Spec;
use lib 't/lib';

use JSON::PP qw/encode_json/;
use Local::MockUA;
use Webservice::Overleaf::API;


{
    package Local::CompileNoPdfUrl;
    sub new { bless {}, shift }
    sub pdf_url { return }

    package Local::CompileNoFiles;
    sub new { bless {}, shift }
    sub output_files { return }

    package Local::OutputNoPath;
    sub new { bless {}, shift }
    sub path { return }
    sub url { return 'https://cdn/no-path' }

    package Local::OutputNoUrl;
    sub new { my ($class, $url) = @_; bless { url => $url }, $class }
    sub path { return 'x' }
    sub url { return $_[0]->{url} }

    package main;
}

sub response {
    my ($content, %extra) = @_;
    return {
        success => exists($extra{success}) ? delete($extra{success}) : 1,
        status  => exists($extra{status})  ? delete($extra{status})  : 200,
        reason  => exists($extra{reason})  ? delete($extra{reason})  : 'OK',
        headers => delete($extra{headers}) || {},
        content => defined($content) ? $content : q{},
        %extra,
    };
}

sub html_json {
    my ($name, $data) = @_;
    my $json = encode_json($data);
    $json =~ s/&/&amp;/g;
    $json =~ s/"/&quot;/g;
    return qq{<meta name="$name" content="$json">};
}

# Constructor variants, URL normalization, env session, and raw headers.
{
    local $ENV{OVERLEAF_SESSION} = 'from-env';
    my $ol = Webservice::Overleaf::API->new(
        base_url     => 'https://latex.example.edu///',
        git_base_url => 'https://git.example.edu///',
        cookie_name  => 'sharelatex.sid',
        csrf         => 'given-csrf',
        timeout      => 9,
    );
    is $ol->base_url, 'https://latex.example.edu', 'base URL trailing slashes trimmed';
    is $ol->git_base_url, 'https://git.example.edu', 'explicit git base trailing slashes trimmed';
    is $ol->session, 'from-env', 'session falls back to environment';
    is $ol->timeout, 9, 'custom timeout retained';
    is $ol->cookie_name, 'sharelatex.sid', 'custom cookie name retained';
    my $h = $ol->_headers;
    is $h->{Cookie}, 'sharelatex.sid=from-env', 'custom cookie header';
    is $h->{'X-Csrf-Token'}, 'given-csrf', 'csrf header included';
    like $h->{'User-Agent'}, qr{Webservice-Overleaf-API/0\.01}, 'user agent header';

    my $plain = Webservice::Overleaf::API->new(session => '', csrf => '');
    my $ph = $plain->_headers;
    ok !exists($ph->{Cookie}), 'no cookie header for empty session';
    ok !exists($ph->{'X-Csrf-Token'}), 'no csrf header for empty token';

    {
        local $ENV{OVERLEAF_SESSION};
        my $undefh = Webservice::Overleaf::API->new;
        my $uh = $undefh->_headers;
        ok !exists($uh->{Cookie}), 'no cookie header for undefined session';
        ok !exists($uh->{'X-Csrf-Token'}), 'no csrf header for undefined token';
    }
}

# Official Open-in-Overleaf API edge cases.
{
    my $ol = Webservice::Overleaf::API->new;
    like $ol->open_uri(uris => 'https://e/single.tex'), qr{snip_uri=}, 'scalar uris accepted';
    like $ol->open_uri(uri => 'https://e/single.tex', names => 'renamed.tex'), qr{snip_name%5B%5D=renamed\.tex}, 'single name forces array form';
    like $ol->open_uri(uri => 'https://e/single.tex', name => 'singular.tex'), qr{snip_name%5B%5D=singular\.tex}, 'singular name option accepted';
    like $ol->open_uri(uris => ['https://e/a.tex', 'https://e/b.tex']), qr{snip_uri%5B%5D=.*snip_uri%5B%5D=}, 'multiple URIs without names accepted';
    like $ol->open_uri(uri => 'https://e/single.tex', visual_editor => 0), qr{visual_editor=false}, 'visual editor false encoded';
    like $ol->open_uri(uri => 'https://e/single.tex', engine => 'latex_dvipdf'), qr{engine=latex_dvipdf}, 'latex_dvipdf accepted';
    like $ol->open_uri(uri => 'https://e/single.tex', engine => 'xelatex'), qr{engine=xelatex}, 'xelatex accepted';
    like $ol->open_uri(uri => 'https://e/single.tex', engine => 'lualatex'), qr{engine=lualatex}, 'lualatex accepted';

    for my $bad (
        sub { $ol->open_uri() },
        sub { $ol->open_uri(uri => '') },
        sub { $ol->open_uri(uris => []) },
        sub { $ol->open_uri(uris => ['https://e/a', undef]) },
    ) {
        my $ok = eval { $bad->(); 1 };
        ok !$ok, 'missing/blank URI rejected';
        like $@, qr/open_uri requires/, 'URI diagnostic';
    }

    my $ok = eval { $ol->open_uri(uri => 'https://e/a', surprise => 1); 1 };
    ok !$ok, 'unknown open_uri option rejected';
    like $@, qr/unsupported open_uri option/, 'unknown open_uri option diagnostic';

    $ok = eval { $ol->open_data(undef); 1 };
    ok !$ok, 'undefined open_data content rejected';
    like $@, qr/open_data requires content/, 'open_data diagnostic';
    like $ol->open_data('abc'), qr{data%3Aapplication%2Fx-tex}, 'open_data default MIME';

    $ok = eval { $ol->open_snippet_form(undef); 1 };
    ok !$ok, 'undefined snippet rejected';
    like $@, qr/requires a snippet/, 'snippet diagnostic';
    $ok = eval { $ol->open_snippet_form('x', surprise => 1); 1 };
    ok !$ok, 'unknown snippet option rejected';
    like $@, qr/unsupported open_snippet_form option/, 'snippet option diagnostic';
}

# Git guards, custom remote, and default runner success/failure/system failure.
{
    my @cmd;
    my $ol = Webservice::Overleaf::API->new(git_runner => sub { push @cmd, [@_]; 0 });
    ok $ol->git_remote_add('repo', 'p1', 'upstream'), 'custom remote added';
    is $cmd[-1]->[5], 'upstream', 'custom remote name used';

    for my $case (
        [git_clone      => ['p1', undef], qr/destination directory/],
        [git_clone      => ['p1', ''],    qr/destination directory/],
        [git_pull       => [undef],       qr/repository directory/],
        [git_pull       => [''],          qr/repository directory/],
        [git_push       => [undef],       qr/repository directory/],
        [git_push       => [''],          qr/repository directory/],
        [git_remote_add => [undef, 'p1'], qr/repository directory/],
        [git_remote_add => ['', 'p1'],    qr/repository directory/],
    ) {
        my ($method, $args, $re) = @$case;
        my $ok = eval { $ol->$method(@$args); 1 };
        ok !$ok, "$method guard throws";
        like $@, $re, "$method guard diagnostic";
    }

    my $ok = eval { $ol->project_url(undef); 1 };
    ok !$ok, 'missing project id rejected';
    like $@, qr/project id is required/, 'missing project id diagnostic';
    $ok = eval { $ol->project_url(''); 1 };
    ok !$ok, 'empty project id rejected';
    like $@, qr/project id is required/, 'empty project id diagnostic';

    is Webservice::Overleaf::API::_default_git_runner($^X, '-e', 'exit 0'), 0, 'default runner success';
    is Webservice::Overleaf::API::_default_git_runner($^X, '-e', 'exit 7'), 7, 'default runner returns child status';
    {
        open my $null, '>', File::Spec->devnull or die $!;
        local *STDERR = $null;
        is Webservice::Overleaf::API::_default_git_runner('/definitely/not/a/command'), 255, 'default runner maps system failure to 255';
    }
}

# CSRF extraction permutations and attribute/meta parsing.
{
    is Webservice::Overleaf::API::_csrf_from_html(q{<meta NAME='ol-csrfToken' CONTENT=bare-token>}), 'bare-token', 'meta token with single/bare attrs';
    is Webservice::Overleaf::API::_csrf_from_html(q{<form><input name="_csrf" value="input-token"></form>}), 'input-token', 'hidden input token';
    is Webservice::Overleaf::API::_csrf_from_html(q{<script>window.csrfToken = 'script-token';</script>}), 'script-token', 'script token';
    ok !defined(Webservice::Overleaf::API::_csrf_from_html('<html></html>')), 'missing CSRF returns undef';
    ok !defined(Webservice::Overleaf::API::_csrf_from_html(q{<meta content="x"><meta name="wrong" content="y"><meta name="ol-csrfToken"><input value="x"><input name="wrong" value="y"><input name="_csrf">})), 'incomplete/wrong CSRF elements ignored';

    my $attrs = Webservice::Overleaf::API::_attrs(q{A="x&amp;y" b='two' c=three});
    is_deeply $attrs, { a => 'x&y', b => 'two', c => 'three' }, 'attribute parser covers quoted and bare values';

    my @meta = Webservice::Overleaf::API::_meta_tags('<META name="a" content="1"><meta name="b" content="2">');
    is scalar(@meta), 2, 'meta parser is case insensitive';
}

# JSON normalization and URL helpers.
{
    ok !defined(Webservice::Overleaf::API::_projects_from_json(undef)), 'undefined project JSON ignored';
    ok !defined(Webservice::Overleaf::API::_projects_from_json('')), 'empty project JSON ignored';
    ok !defined(Webservice::Overleaf::API::_projects_from_json('{bad')), 'invalid project JSON ignored';
    ok !defined(Webservice::Overleaf::API::_projects_from_json('null')), 'JSON null ignored';
    my $array = Webservice::Overleaf::API::_projects_from_json('[{"id":"a"}]');
    is ref($array), 'ARRAY', 'top-level project array accepted';
    my $wrapped = Webservice::Overleaf::API::_projects_from_json('{"projects":[{"id":"b"}]}');
    is $wrapped->[0]->{id}, 'b', 'wrapped projects accepted';
    ok !defined(Webservice::Overleaf::API::_projects_from_json('{"other":1}')), 'unrecognized JSON shape ignored';
    ok !defined(Webservice::Overleaf::API::_projects_from_json('"scalar"')), 'scalar JSON shape ignored';

    is Webservice::Overleaf::API::_absolute_url('https://base', undef), '', 'undefined URL becomes empty';
    is Webservice::Overleaf::API::_absolute_url('https://base', 'HTTP://x/y'), 'HTTP://x/y', 'absolute URL retained';
    is Webservice::Overleaf::API::_absolute_url('https://base', '/x'), 'https://base/x', 'root-relative URL expanded';
    is Webservice::Overleaf::API::_absolute_url('https://base', 'x'), 'https://base/x', 'relative URL expanded';

    is Webservice::Overleaf::API::_query_string(['x', undef]), 'x=', 'undefined query value encoded empty';
}

# Bootstrap success/failure and project metadata fallbacks.
{
    my $ua = Local::MockUA->new;
    $ua->enqueue(response('<meta name="ol-csrfToken" content="boot">'));
    my $ol = Webservice::Overleaf::API->new(ua => $ua, experimental => 1, session => 's');
    my $boot = $ol->bootstrap;
    ok $boot->authenticated, 'bootstrap marks authenticated';
    is $boot->csrf, 'boot', 'bootstrap returns CSRF';
    is $ol->_ensure_csrf, 'boot', '_ensure_csrf returns existing token';

    my $badua = Local::MockUA->new;
    $badua->enqueue(response('<html>no token</html>'));
    my $bad = Webservice::Overleaf::API->new(ua => $badua, experimental => 1, session => 's');
    my $ok = eval { $bad->bootstrap; 1 };
    ok !$ok, 'bootstrap without CSRF fails';
    like $@, qr/could not find.*CSRF token/i, 'bootstrap failure diagnostic';


    my $emptycsrfua = Local::MockUA->new;
    $emptycsrfua->enqueue(response('<meta name="ol-csrfToken" content="">'));
    my $emptycsrf = Webservice::Overleaf::API->new(ua => $emptycsrfua, experimental => 1, session => 's');
    $ok = eval { $emptycsrf->bootstrap; 1 };
    ok !$ok, 'bootstrap with empty CSRF fails';

    my $ensureua = Local::MockUA->new;
    $ensureua->enqueue(response('<meta name="ol-csrfToken" content="ensured">'));
    my $ensure = Webservice::Overleaf::API->new(ua => $ensureua, experimental => 1, session => 's', csrf => '');
    is $ensure->_ensure_csrf, 'ensured', '_ensure_csrf bootstraps when token is empty';

    {
        local $ENV{OVERLEAF_SESSION};
        my $none = Webservice::Overleaf::API->new(experimental => 1, ua => Local::MockUA->new);
        $ok = eval { $none->_require_session; 1 };
        ok !$ok, 'undefined session rejected';
        like $@, qr/session cookie is required/, 'undefined session diagnostic';
    }

    my $prefempty = Local::MockUA->new;
    $prefempty->enqueue(response('<meta name="ol-csrfToken" content=""><meta name="ol-prefetchedProjectsBlob" content="{&quot;projects&quot;:[]}">'));
    my $pe = Webservice::Overleaf::API->new(ua => $prefempty, experimental => 1, session => 's');
    is $pe->projects->scalar, 0, 'empty prefetched projects accepted and empty CSRF ignored';

    my $genericempty = Local::MockUA->new;
    $genericempty->enqueue(response('<meta content="{&quot;projects&quot;:[]}">'));
    my $ge = Webservice::Overleaf::API->new(ua => $genericempty, experimental => 1, session => 's');
    is $ge->projects->scalar, 0, 'empty generic project list reaches legacy fallback cleanly';

    my $intermediate = Local::MockUA->new;
    $intermediate->enqueue(response('<meta content="{&quot;projects&quot;:[{&quot;_id&quot;:&quot;i1&quot;,&quot;name&quot;:&quot;Intermediate&quot;}]}">'));
    my $i = Webservice::Overleaf::API->new(ua => $intermediate, experimental => 1, session => 's');
    my ($ip) = $i->projects->all;
    is $ip->id, 'i1', 'intermediate project meta fallback';
    is $ip->archived, 0, 'normalized archived false';
    is $ip->trashed, 0, 'normalized trashed false';

    my $legacy = Local::MockUA->new;
    $legacy->enqueue(response(html_json('ol-projects', [
        { id => 'l1', name => 'Legacy', lastUpdatedBy => 'u', owner => { email => 'a\@b' } },
        'not-a-hash',
    ])));
    my $l = Webservice::Overleaf::API->new(ua => $legacy, experimental => 1, session => 's');
    my ($lp) = $l->projects->all;
    is $lp->id, 'l1', 'legacy project meta fallback';
    is $lp->last_updated_by, 'u', 'last_updated_by normalized';
    is $lp->owner->email, 'a\@b', 'owner retained and objectified';

    my $empty = Local::MockUA->new;
    $empty->enqueue(response('<meta name="only-name"><meta name="ol-prefetchedProjectsBlob" content="{bad"><meta content="{&quot;projects&quot;:bad}"><meta content="no projects here">'));
    my $e = Webservice::Overleaf::API->new(ua => $empty, experimental => 1, session => 's');
    is $e->projects->scalar, 0, 'malformed/no project metadata yields empty list';
}

# Compile success variants and failure responses.
{
    my $ua = Local::MockUA->new;
    $ua->enqueue(
        response('<input name="_csrf" value="fresh-csrf">'),
        response(encode_json({
            status => 'success',
            clsiServerId => '',
            outputFiles => [
                'junk',
                { path => 'notype', url => '/notype' },
                { type => 'log', url => '/nopath' },
                { path => 'figure', type => 'pdf', url => 'relative.pdf' },
                { path => 'log', type => 'log', url => 'https://cdn.example/log' },
            ],
        })),
    );
    my $ol = Webservice::Overleaf::API->new(ua => $ua, experimental => 1, session => 's');
    my $c = $ol->compile('p1');
    is $c->pdf_url, 'https://www.overleaf.com/relative.pdf', 'fallback PDF type and relative URL';
    ok !defined($c->compile_group), 'undefined compile group retained';
    is $c->clsi_server_id, '', 'empty CLSI id retained without query string';

    my $emptyrpua = Local::MockUA->new;
    $emptyrpua->enqueue(response(encode_json({ status => 'success', outputFiles => [ {path=>'output.pdf',type=>'pdf',url=>'/e'} ] })));
    my $emptyrp = Webservice::Overleaf::API->new(ua => $emptyrpua, experimental => 1, session => 's', csrf => 'c');
    my $emptyrpc = $emptyrp->compile('p1', resource_path => '');
    ok !exists(JSON::PP::decode_json($emptyrpua->last_request->{opts}->{content})->{rootResourcePath}), 'empty resource_path omitted from compile body';

    my @bad = (
        ['not-json', {}, qr/not valid JSON/],
        [encode_json([]), {}, qr/not valid JSON/],
        [encode_json({ status => 'failure' }), {}, qr/compilation failed: failure/],
        [encode_json({ status => 'failure' }), {resource_path => 'missing.tex'}, qr/requested resource file may not exist/],
        [encode_json({}), {}, qr/compilation failed: error/],
        [encode_json({ status => 'success', outputFiles => [] }), {}, qr/no PDF output/],
        [encode_json({ status => 'success' }), {}, qr/no PDF output/],
    );
    for my $case (@bad) {
        my ($payload, $opts, $re) = @$case;
        my $bu = Local::MockUA->new;
        $bu->enqueue(response($payload));
        my $b = Webservice::Overleaf::API->new(ua => $bu, experimental => 1, session => 's', csrf => 'already');
        my $ok = eval { $b->compile('p1', %$opts); 1 };
        ok !$ok, 'compile error case throws';
        like $@, $re, 'compile error diagnostic';
    }
}

# Download variants and save/error paths.
{
    my $autoua = Local::MockUA->new;
    $autoua->enqueue(
        response(encode_json({ status => 'success', outputFiles => [ {path=>'output.pdf', type=>'pdf', url=>'/auto.pdf'} ] })),
        response('PDF-AUTO'),
    );
    my $auto = Webservice::Overleaf::API->new(ua => $autoua, experimental => 1, session => 's', csrf => 'c');
    is $auto->download_pdf('p1'), 'PDF-AUTO', 'download_pdf compiles automatically when no result supplied';

    my $ua = Local::MockUA->new;
    $ua->enqueue(response('PDF-HASH'));
    my $ol = Webservice::Overleaf::API->new(ua => $ua, experimental => 1, session => 's');
    is $ol->download_pdf('p1', compile => { pdf_url => 'https://cdn/pdf' }), 'PDF-HASH', 'hash compile result supported';

    my $obj_no_pdf = Local::CompileNoPdfUrl->new;
    my $ok = eval { $ol->download_pdf('p1', compile => $obj_no_pdf); 1 };
    ok !$ok, 'object compile result with undefined pdf_url rejected';
    like $@, qr/does not contain pdf_url/, 'object missing pdf_url diagnostic';

    $ok = eval { $ol->download_pdf('p1', compile => {}); 1 };
    ok !$ok, 'missing pdf_url rejected';
    like $@, qr/does not contain pdf_url/, 'missing pdf_url diagnostic';

    $ok = eval { $ol->download_output(undef, 'x'); 1 };
    ok !$ok, 'missing compile result rejected';
    like $@, qr/requires a compile result/, 'missing compile diagnostic';
    $ok = eval { $ol->download_output({}, undef); 1 };
    ok !$ok, 'missing output path rejected';

    $ok = eval { $ol->download_output(Local::CompileNoFiles->new, 'x'); 1 };
    ok !$ok, 'object compile result with undefined output_files rejected';
    like $@, qr/does not contain output_files/, 'object missing output_files diagnostic';

    $ok = eval { $ol->download_output({}, 'x'); 1 };
    ok !$ok, 'missing output_files rejected';
    like $@, qr/does not contain output_files/, 'missing output_files diagnostic';

    $ok = eval { $ol->download_output({ output_files => [ Local::OutputNoPath->new ] }, 'x'); 1 };
    ok !$ok, 'object output with undefined path does not match';
    like $@, qr/was not found/, 'undefined object path ignored';

    $ok = eval { $ol->download_output({ output_files => [] }, 'x'); 1 };
    ok !$ok, 'unknown output path rejected';
    like $@, qr/was not found/, 'unknown output diagnostic';

    for my $missing_url (undef, '') {
        my $badurl = Local::OutputNoUrl->new($missing_url);
        $ok = eval { $ol->download_output({ output_files => [ $badurl ] }, 'x'); 1 };
        ok !$ok, 'missing/empty output URL rejected';
        like $@, qr/does not contain a URL/, 'missing/empty output URL diagnostic';
    }

    my $outua = Local::MockUA->new;
    $outua->enqueue(response('HASH-OUT'));
    my $out = Webservice::Overleaf::API->new(ua => $outua, experimental => 1, session => 's');
    is $out->download_output({ output_files => [ { path => 'x', url => 'https://cdn/x' } ] }, 'x'), 'HASH-OUT', 'hash output entry supported';

    my $tmp = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($tmp, 'saved.bin');
    is Webservice::Overleaf::API::_save_or_return('abc', $file), $file, 'save helper returns path';
    open my $fh, '<:raw', $file or die $!;
    is do { local $/; <$fh> }, 'abc', 'save helper writes bytes';
    close $fh;

    $ok = eval { Webservice::Overleaf::API::_save_or_return('x', File::Spec->catfile($tmp, 'missing', 'x')); 1 };
    ok !$ok, 'save open error throws';
    like $@, qr/could not write/, 'save open error diagnostic';

    if (-e '/dev/full') {
        $ok = eval { Webservice::Overleaf::API::_save_or_return('x', '/dev/full'); 1 };
        ok !$ok, 'save close error throws on /dev/full';
        like $@, qr/could not close/, 'save close error diagnostic';
    }
    else {
        pass('/dev/full unavailable; close-error branch is Linux CI covered');
        pass('/dev/full unavailable; close-error diagnostic is Linux CI covered');
    }
}

# HTTP request response classes, lazy HTTP::Tiny construction, and last_response.
{
    my $ua = Local::MockUA->new;
    $ua->enqueue(response('ok'));
    my $ol = Webservice::Overleaf::API->new(ua => $ua, experimental => 1, session => 's');
    is $ol->project_zip('p1'), 'ok', 'successful request returns content';
    is $ol->last_response->{status}, 200, 'last response retained';

    for my $r (
        response('no', success => 0, status => 403, reason => 'Forbidden'),
        { success => 0, status => undef, reason => undef, headers => {}, content => 'no' },
    ) {
        my $eu = Local::MockUA->new;
        $eu->enqueue($r);
        my $e = Webservice::Overleaf::API->new(ua => $eu, experimental => 1, session => 's');
        my $ok = eval { $e->project_zip('p1'); 1 };
        ok !$ok, 'HTTP error throws';
        like $@, $r->{status} && $r->{status} == 403 ? qr/authentication failed.*403/i : qr/HTTP \? /, 'HTTP error class diagnostic';
    }

    my $mock = Local::MockUA->new;
    $mock->enqueue(response('lazy'));
    my $created;
    {
        no warnings 'redefine';
        local *HTTP::Tiny::new = sub { $created++; return $mock };
        my $lazy = Webservice::Overleaf::API->new(experimental => 1, session => 's', timeout => 4);
        is $lazy->project_zip('p1'), 'lazy', 'lazy HTTP client path works';
        is $created, 1, 'HTTP::Tiny constructed once';
        is $lazy->ua, $mock, 'constructed UA cached';
    }
}

# Every Dispatch::Fu public operation handler is exercised.
{
    my @git;
    my $ua = Local::MockUA->new;
    my $ol = Webservice::Overleaf::API->new(
        ua => $ua, experimental => 1, session => 's', csrf => 'csrf',
        git_runner => sub { push @git, [@_]; 0 },
    );

    like $ol->call('open_data', 'x'), qr{snip_uri=data}, 'dispatch open_data';
    ok $ol->call('git_clone', 'p1', 'repo'), 'dispatch git_clone';
    ok $ol->call('git_pull', 'repo'), 'dispatch git_pull';
    ok $ol->call('git_push', 'repo'), 'dispatch git_push';

    $ua->enqueue(response('<meta name="ol-projects" content="[]">'));
    is $ol->call('projects')->scalar, 0, 'dispatch projects';

    $ua->enqueue(response('ZIP'));
    is $ol->call('project_zip', 'p1'), 'ZIP', 'dispatch project_zip';

    $ua->enqueue(response(encode_json({ status => 'success', outputFiles => [ {path=>'output.pdf',type=>'pdf',url=>'/p'} ] })));
    my $c = $ol->call('compile', 'p1');
    is $c->status, 'success', 'dispatch compile';

    $ua->enqueue(response('PDF'));
    is $ol->call('download_pdf', 'p1', compile => $c), 'PDF', 'dispatch download_pdf';
}

done_testing;

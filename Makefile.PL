use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'WebService::Google::Reader',
    AUTHOR        => 'gray <gray@cpan.org>',
    LICENSE       => 'perl',
    VERSION_FROM  => 'lib/WebService/Google/Reader.pm',
    ABSTRACT_FROM => 'lib/WebService/Google/Reader.pm',
    PREREQ_PM     => {
        'Class::Accessor::Fast' => 0,
        'Crypt::SSLeay'         => 0,
        'HTTP::Request'         => 0,
        'LWP::UserAGent'        => 0,
        'Test::More'            => 0,
        'URI'                   => 0,
        'URI::Escape'           => 0,
        'XML::Atom'             => 0,
    },
    dist          => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean         => { FILES => 'WebServce-Google-Reader-*' },
);

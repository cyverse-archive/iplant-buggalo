use 5.006;
use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name        => 'IPlant::Buggalo',
    license            => 'apache',
    dist_author        => q{Dennis Roberts <dennis@iplantcollaborative.org>},
    dist_version_from  => 'lib/IPlant/Buggalo.pm',
    build_requires     => { 'Test::More' => 0, },
    configure_requires => { 'Module::Build' => 0.38 },
    requires           => {
        'Apache2::Const'        => '2.000004',
        'Apache2::Request'      => '2.08',
        'Apache2::Response'     => '2.000004',
        'Apache2::RequestRec'   => '2.000004',
        'Apache2::RequestIO'    => '2.000004',
        'Carp'                  => 0,
        'English'               => 0,
        'File::Basename'        => 0,
        'HTTP::Request::Common' => '5.811',
        'JSON'                  => '2.22',
        'LWP::UserAgent'        => '5.813',
        'Readonly'              => '1.03',
        'URI::Escape'           => '3.29',
        'Inline::CPP'           => '0.25',
        'Inline'                => '0.48',
        'perl'                  => 5.006,
    },
    add_to_cleanup     => ['IPlant-Buggalo-*'],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();

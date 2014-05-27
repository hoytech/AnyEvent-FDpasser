use ExtUtils::MakeMaker;

use strict;

my $define;

if (exists $ENV{FDPASSER_SYSV}) {
  $define = '-DFDPASSER_SYSV';
} else {
  $define = '-DFDPASSER_BSD';
}

my %args = (
  NAME => 'AnyEvent::FDpasser',
  VERSION_FROM => 'lib/AnyEvent/FDpasser.pm',
  LIBS => [''],
  LICENSE => 'perl',
  OBJECT => 'FDpasser.o',
  DEFINE => $define,
  INC => '-I lib/',
  PREREQ_PM => {
    'common::sense' => 0,
    'AnyEvent' => 0,
  },
  dist => {
    PREOP => 'pod2text $(VERSION_FROM) > $(DISTVNAME)/README',
  },
);


my $eummv = eval ($ExtUtils::MakeMaker::VERSION);
if ($eummv >= 6.45) {
    $args{META_MERGE} = {
        resources => {
            repository => 'git://github.com/hoytech/AnyEvent-FDpasser.git',
            bugtracker => 'https://github.com/hoytech/AnyEvent-FDpasser/issues',
        },
    };
}

WriteMakefile(%args);

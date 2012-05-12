use ExtUtils::MakeMaker;

my $define;

if ($^O eq 'solaris') {
  $define = '-DFDPASSER_SYSV';
} else {
  $define = '-DFDPASSER_BSD';
}

WriteMakefile(
  NAME => 'AnyEvent::FDpasser',
  VERSION_FROM => 'lib/AnyEvent/FDpasser.pm',
  LIBS => [''],
  OBJECT => 'FDpasser.o',
  DEFINE => $define,
  INC => '-I lib/',
  PREREQ_PM => {
    'common::sense' => 0,
    'AnyEvent' => 0,
  },
);

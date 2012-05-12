use common::sense;

use BSD::Resource;

use AnyEvent;
use AnyEvent::FDpasser;

use Test::More tests => 1;


## The point of this test is to exercise the full file descriptor code 
## and verify that no descriptors are lost.



my $passer = AnyEvent::FDpasser->new;


if (fork) {
  $passer->is_parent;

  for my $curr (1 .. 30) {
    pipe my $rfh, my $wfh;
    print $wfh "descriptor $curr\n";
    $passer->push_send_fh($rfh);
  }

  $passer->push_recv_fh(sub {
    my $fh = shift;
    my $text = <$fh>;
    is($text, "hooray\n", 'got 30');
    exit;
  });
} else {
  $passer->is_child;

  my $next_desc = 1;
  my @descriptors;

  my $watcher; $watcher = AE::timer 0.5, 0.5, sub {
    $watcher;
    close($_) foreach (@descriptors);
    @descriptors = ();
  };

  setrlimit('RLIMIT_NOFILE', 20, 20);

  for my $curr (1 .. 30) {
    $passer->push_recv_fh(sub {
      my $fh = shift;

      my $text = <$fh>;
      exit unless $text eq "descriptor $next_desc\n";

      $next_desc++;
      push @descriptors, $fh;

      if ($curr == 30) {
        undef @descriptors; ## otherwise pipe() below may fail
        pipe my $rfh, my $wfh;
        print $wfh "hooray\n";
        $passer->push_send_fh($rfh, sub { exit; });
      }
    });
  }
}

AE->cv->recv;

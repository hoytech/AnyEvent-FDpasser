use common::sense;

use AnyEvent;
use AnyEvent::FDpasser;

use Test::More tests => 1;


## The point of this test is to ensure that a socket close error is properly
## detected and reported by the on_error callback.



my $passer = AnyEvent::FDpasser->new( on_error => sub {
                                        my $err = shift;
                                        ok(1, "error callback triggered ok ($err)");
                                        exit;
                                      },
                                    );


if (fork) {
  $passer->is_parent;

  pipe my $rfh, my $wfh;
  print $wfh "hooray\n";
  $passer->push_send_fh($rfh);

  $passer->push_recv_fh(sub {
    ok(0, "received fh?");
    exit;
  });
} else {
  $passer->is_child;

  my $watcher; $watcher = AE::timer 0.02, 0, sub {
    undef $watcher;
    exit;
  };
}

AE->cv->recv;

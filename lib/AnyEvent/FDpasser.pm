package AnyEvent::FDpasser;

use common::sense;

our $VERSION = '0.1';

require XSLoader;
XSLoader::load('AnyEvent::FDpasser', $VERSION);

use Carp;
use Errno;
use POSIX; ## Uses POSIX::pipe/dup so we get accurate $!
use Socket qw/AF_UNIX SOCK_STREAM SOL_SOCKET AF_UNSPEC SO_REUSEADDR/;

use AnyEvent;
use AnyEvent::Util;


sub new {
  my ($class, %arg) = @_;
  my $self = bless {}, $class;

  $self->{on_error} = $arg{on_error};

  $self->{obuf} = [];
  $self->{ibuf} = [];

  if (ref $arg{fh} eq 'ARRAY') {
    die "too many elements in fh array" if scalar @{$arg{fh}} > 2;
    $self->{fh} = $arg{fh}->[0];
    $self->{fh_pair} = $arg{fh}->[1];
  } else {
    if (!defined $arg{fh}) {
      ($self->{fh}, $self->{fh_pair}) = fdpasser_socketpair();
    } else {
      $self->{fh} = $arg{fh};
    }
  }

  unless ($arg{dont_set_nonblocking}) {
    AnyEvent::Util::fh_nonblocking $self->{fh}, 1;
    AnyEvent::Util::fh_nonblocking $self->{fh_pair}, 1
      if exists $self->{fh_pair};
  }

  $self->setup_fh_duped;

  return $self;
}




sub i_am_parent {
  my ($self) = @_;

  die "i_am_parent only applicable when socketpair used" if !defined $self->{fh_pair};
  die "passer object is in error_state: $self->{error_state}" if exists $self->{error_state};

  close($self->{fh_pair});
  delete $self->{fh_pair};
}

sub i_am_child {
  my ($self) = @_;

  die "i_am_child only applicable when socketpair used" if !defined $self->{fh_pair};
  die "passer object is in error_state: $self->{error_state}" if exists $self->{error_state};

  close($self->{fh});
  $self->{fh} = $self->{fh_pair};
  delete $self->{fh_pair};
}




sub push_send_fh {
  my ($self, $fh_to_send, $cb) = @_;

  die "passer object is in error_state: $self->{error_state}" if exists $self->{error_state};
  die "must call i_am_parent or i_am_child" if exists $self->{fh_pair};

  $cb ||= sub {};

  push @{$self->{obuf}}, [$fh_to_send, $cb];

  $self->try_to_send;
}


sub push_recv_fh {
  my ($self, $cb) = @_;

  die "passer object is in error_state: $self->{error_state}" if exists $self->{error_state};
  die "must call i_am_parent or i_am_child" if exists $self->{fh_pair};

  push @{$self->{ibuf}}, $cb;

  $self->try_to_recv;
}




sub try_to_send {
  my ($self) = @_;

  return unless $self->{fh};
  return unless @{$self->{obuf}};
  return if defined $self->{owatcher};
  return if defined $self->{full_descriptor_table_state};

  $self->{owatcher} = AE::io $self->{fh}, 1, sub {

    my $fh_to_send = shift @{$self->{obuf}};

    my $rv = send_fd(fileno($self->{fh}), fileno($fh_to_send->[0]));

    if ($rv < 0) {
      if ($!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR}) {
        ## Spurious ready notification or signal: put fh back on queue
        unshift @{$self->{obuf}}, $fh_to_send;
      } else {
        ## Unknown error
        $self->error($!);
      }
    } elsif ($rv == 0) {
      $self->error('sendmsg wrote 0 bytes');
    } else {
      $fh_to_send->[1]->();
      ## Don't do a close($fh_to_send->[0]) because the program may wish to keep it alive
      undef $fh_to_send;
      $self->{owatcher} = undef;
      $self->try_to_send;
    }

  };
}


sub try_to_recv {
  my ($self) = @_;

  return unless @{$self->{ibuf}};
  return if defined $self->{iwatcher};
  return if defined $self->{full_descriptor_table_state};

  $self->{iwatcher} = AE::io $self->{fh}, 0, sub {

    my $cb = shift @{$self->{ibuf}};

    POSIX::close($self->{fh_duped});
    delete $self->{fh_duped};

    ## Race condition: If another thread or a signal handler creates a new descriptor at this
    ## exact point in time, it could cause the descriptor table to fill up and the following
    ## to error.

    my $rv = recv_fd(fileno($self->{fh}));

    if ($rv == -1) {
      if ($!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR}) {
        ## Spurious ready notification or signal: put the cb back on the queue
        unshift @{$self->{ibuf}}, $cb;
      } elsif ($!{EMSGSIZE} || $!{EMFILE} || $!{ENFILE}) {
        ## File descriptor table is full. This should be very unlikely given the close+duping
        ## technique used to detect this. In this case the descriptor stream may be
        ## desynchronised and we must shutdown the passer.

        my $err = $!;

        carp "AnyEvent::FDpasser - file descriptor table full, closing passer: $!";

        $self->error($err);
      } else {
        ## Unknown error
        $self->error($!);
      }
    } elsif ($rv == -2) {
      $self->error("cmsg truncated");
    } elsif ($rv == 0) {
      ## Orderly shutdown
      $self->error(undef);
    } else {
      open(my $new_fh, '+<&=', $rv);
      $self->{iwatcher} = undef;
      $cb->($new_fh);
      $self->try_to_recv;
    }
  };

  $self->setup_fh_duped;
}





sub _convert_fh_to_fd {
  my $fh = shift;
  $fh = fileno($fh) unless $fh =~ /^\d+$/;
  return $fh;
}

sub fdpasser_socketpair {
  my ($s1, $s2);

  if ($^O eq 'MSWin32') {
    die "AnyEvent::FDpasser does not support windows";
  } elsif (fdpasser_mode() == 2) {
    pipe $s1, $s2;
    die "can't pipe: $!" unless $s1;
  } else {
    socketpair $s1, $s2, AF_UNIX, SOCK_STREAM, AF_UNSPEC;
    die "can't make socketpair: $!" unless $s2;
  }

  return ($s1, $s2);
}

sub fdpasser_server {
  my ($path, $backlog) = @_;

  $backlog ||= 10;

  my $fh;

  if ($^O eq 'MSWin32') {
    die "AnyEvent::FDpasser does not support windows";
  } elsif (fdpasser_mode() == 2) {
    my $fd = _fdpasser_server($path);
    die "unable to _fdpasser_server($path) : $!" if $fd < 0;
    open($fh, '+<&=', $fd) || die "couldn't open";
  } else {
    socket($fh, AF_UNIX, SOCK_STREAM, AF_UNSPEC) || die "Unable to create AF_UNIX socket: $!";
    setsockopt($fh, SOL_SOCKET, SO_REUSEADDR, pack("l", 1)) || die "Unable to setsockopt(SO_REUSEADDR): $!";
    unlink($path);
    bind($fh, Socket::sockaddr_un($path)) || die "Unable to bind AF_UNIX socket to $path : $!";
    listen($fh, $backlog) || die "Unable to listen on $path : $!";
  }

  return $fh;
}

sub fdpasser_accept {
  my ($listener_fh) = @_;

  my $passer_fh;

  if ($^O eq 'MSWin32') {
    die "AnyEvent::FDpasser does not support windows";
  } elsif (fdpasser_mode() == 2) {
    my $fd = _fdpasser_accept(fileno($listener_fh));
    die "unable to _fdpasser_accept($listener_fh) : $!" if $fd < 0;
    open($passer_fh, '+<&=', $fd) || die "couldn't open";
  } else {
    accept($passer_fh, $listener_fh);
  }

  return $passer_fh;
}

sub fdpasser_connect {
  my ($path) = @_;

  my $fh;

  if ($^O eq 'MSWin32') {
    die "AnyEvent::FDpasser does not support windows";
  } elsif (fdpasser_mode() == 2) {
    my $fd = _fdpasser_connect($path);
    die "unable to _fdpasser_connect($path) : $!" if $fd < 0;
    open($fh, '+<&=', $fd) || die "couldn't open";
  } else {
    socket($fh, AF_UNIX, SOCK_STREAM, AF_UNSPEC) || die "Unable to create AF_UNIX socket: $!";
    connect($fh, Socket::sockaddr_un($path)) || die "Unable to connect AF_UNIX socket to $path : $!";
  }

  return $fh;
}


sub error {
  my ($self, $err) = @_;

  my $on_error = $self->{on_error};
  close($self->{fh});
  close($self->{fh_pair}) if exists $self->{fh_pair};

  if (exists $self->{fh_duped}) {
    POSIX::close($self->{fh_duped});
    delete $self->{fh_duped};
  }
  if (exists $self->{fh_duped_orig}) {
    POSIX::close($self->{fh_duped_orig});
    delete $self->{fh_duped_orig};
  }

  delete $self->{$_} foreach (qw/owatcher iwatcher obuf ibuf fh fh_pair fh_duped fh_duped_orig on_error/);

  $self->{error_state} = $err;

  {
    local $@ = $err;
    $on_error->() if $on_error;
  }
}


sub DESTROY {
  my ($self) = @_;

  if (exists $self->{fh_duped}) {
    POSIX::close($self->{fh_duped});
    delete $self->{fh_duped};
  }
  if (exists $self->{fh_duped_orig}) {
    POSIX::close($self->{fh_duped_orig});
    delete $self->{fh_duped_orig};
  }
}


sub setup_fh_duped {
  my ($self) = @_;

  return if exists $self->{fh_duped};

  if (!exists $self->{fh_duped_orig}) {
    my ($r, $w) = POSIX::pipe();
    die "can't call pipe: $!" unless defined $r;
    POSIX::close($w);
    $self->{fh_duped_orig} = $r;
  }

  $self->{fh_duped} = POSIX::dup($self->{fh_duped_orig});

  if (!defined $self->{fh_duped}) {
    delete $self->{fh_duped};
    if ($!{EMFILE} || $!{ENFILE}) {
      ## Descriptor table full: have to make sure not to call recvmsg now
      $self->enter_full_descriptor_table_state;
    } else {
      die "unable to dup descriptor for reason other than full descriptor table: $!";
    }
  }
}

sub enter_full_descriptor_table_state {
  my ($self) = @_;

  return if $self->{full_descriptor_table_state};

  $self->{full_descriptor_table_state} = 1;

  undef $self->{iwatcher};

  my $watcher; $watcher = AE::timer 0.05, 0.5, sub {
    $self->setup_fh_duped;
    if (exists $self->{fh_duped}) {
      undef $watcher;
      delete $self->{full_descriptor_table_state};
      $self->try_to_recv;
    }
  };
}


1;

__END__



=head1 NAME

AnyEvent::FDpasser - pass file descriptors between processes using non-blocking buffers

=head1 SYNOPSIS

    use AnyEvent;
    use AnyEvent::FDpasser;

    my $passer = AnyEvent::FDpasser->new;

    if (fork) {
      $passer->i_am_parent;

      open(my $fh, '>>', '/tmp/fdpasser_output') || die;
      syswrite $fh, "This line is from PID $$\n";

      $passer->push_send_fh($fh);

      undef $fh; # don't close() it though
    } else {
      $passer->i_am_child;

      $passer->push_recv_fh(sub {
        my $fh = shift;

        syswrite $fh, "This line is from PID $$\n";
      });
    }

    AE->cv->recv; # AnyEvent main loop



=head1 DESCRIPTION

This module provides an object oriented interface for passing filehandles between processes. Its primary goals are API simplicity, portability, and reliability. It is suitable for use in non-blocking programs where blocking in even exceptional circumstances is undesirable. Finally, this module should be efficient enough for nearly all use-cases.

This module currently works on BSD4.4-like systems (*BSD, Linux, Mac OS X) where it uses the C<SCM_RIGHTS> ancillary data feature over C<AF_UNIX> sockets, on BSD4.3-like systems (Solaris, IRIX?) where it uses C<msg_accrights> field of C<msghdr> over C<AF_UNIX> sockets, and on SysV-like systems (Solaris, HP-UX, AIX?) where it uses the C<ioctl(I_SENDFD/I_RECVFD)> feature of STREAMS pipes.

Note that a passer object is "bidrectional" and you can use the same object to both send and receive filehandles (each side has a separate input and output buffer).

After sending a filehandle, the sending process will automatically destroy it and you shouldn't close it yourself. Forgetting all references to it is what you should do so that the underlying descriptor is actually closed after it is sent. The exception to this is when you also wish to keep the handle in the sender. Usually you will only do this for sockets that you C<accept()> from.



=over 4

=item my $passer = AnyEvent::FDpasser->new([ fh => <handle(s)>,][ dont_set_nonblocking => 1,][ on_error => $cb->(),])

    ## Both of these are the same
    my $passer = AnyEvent::FDpasser->new;
    my $passer = AnyEvent::FDpasser->new( fh => [ AnyEvent::FDpasser::fdpasser_socketpair ] );

    ## Make sure filehandles are AF_UNIX sockets (BSD) or STREAMS pipes (SysV)
    my $passer = AnyEvent::FDpasser->new( fh => [$fh1, $fh2] );

    ## No i_am_parent or i_am_child required in this case:
    my $passer = AnyEvent::FDpasser->new( fh => $fh, );

When creating a passer objects with two filehandles, it is assumed you want to fork. After you fork you are then supposed call C<< $passer->i_am_parent >> and C<< $passer->i_am_child >>. Creating a passer object with zero filehandles automatically creates a socketpair (or pipe on SysV systems) for you after which you should also fork and call C<< $passer->i_am_parent >> and C<< $passer->i_am_child >>.

If you don't plan on forking and instead wish to establish the passing connection via the filesystem, you should only pass one filehandle in. If you only need to support the BSD interface, this filehandle can be created as a normal C<AF_UNIX> socket. If you wish your code to also be portable to SysV systems, see the C<fdpasser_server>, C<fdpasser_accept>, and C<fdpasser_connect> functions described below.

The AnyEvent::FDpasser constructor will set all filehandles to non-blocking mode. You can override this by passing C<dont_set_nonblocking =E<gt> 1,> in. Even though this module will only attempt to send or receive descriptors when the OS has indicated it is ready, some event loops deliver spurious readiness deliveries on sockets so this parameter is not recommended. However, if you are creating passers often and your sockets are known to already be in non-blocking mode, C<dont_set_nonblocking> will provide a slight performance improvement in that it avoids a couple syscalls.

An error callback can be passed in with the C<on_error> parameter. If an error happens, the passer object will be shutdown and the callback invoked. C<$@> will be set to the error reason or will be undef in the event of an orderly shutdown.



=item $passer->i_am_parent

If forking the passer object, this method must be called by the parent process after forking.


=item $passer->i_am_child

If forking the passer object, this method must be called by the child process after forking.



=item $passer->push_send_fh($fh[, $cb->()])

After calling C<push_send_fh>, the filehandle passed in will be added to an order-preserving queue. Once the main event loop is entered the filehandle will usually be sent immediately since the peer is a local process. However, if the receiving process's socket buffer is full it may not be sent until that buffer is drained.

In any case, the C<push_send_fh> method will not block. If you wish to perform some action once the socket actually has been sent, you can pass a callback as the second argument to C<push_send_fh>. It will be invoked after the descriptor has been sent to the OS and the descriptor has been closed in the sending process, but not necessarily before the receiving process has received the descriptor.

This method is called C<push_send_fh> instead of, say, C<send_fh> to indicate that it is pushing the filehandle onto the end of a queue. Hopefully it should remind you of the similarly named C<push_write> method in L<AnyEvent::Handle>.


=item $passer->push_recv_fh($cb->($fh))

In order to receive the filehandle, the receiving process calls C<push_recv_fh> and passes it a callback that will be called once one is available. The filehandle will be the first argument to this callback.

Note that you can add multiple callbacks with C<push_recv_fh> to the input queue between returning to the main loop. The callbacks will be invoked in the same order that the filehandles are received (which is the same order that they were sent).

This method is called C<push_recv_fh> instead of, say, C<recv_fh> to indicate that it is pushing a callback onto the end of a queue. Hopefully it should remind you of the similarly named C<push_read> method in L<AnyEvent::Handle>.



=item AnyEvent::FDpasser::fdpasser_socketpair()

This function returns two handles representing both ends of a connected socketpair. On BSD systems it uses C<socketpair(2)> and on SysV systems it uses C<pipe(2)>. Note that this function doesn't work on windows so it's not really useful as a fully-generic socketpair. See C<AnyEvent::Util::portable_socketpair> for a windows-portable socketpair (but these handles can only be used with AnyEvent::FDpasser if using the BSD interface).

=item $listener_fh = AnyEvent::FDpasser::fdpasser_server($path[, $backlog ])

This function creates a listening node on the filesystem that other processes can connect to and establish FDpasser-capable connections. It is portable between BSD systems where it uses C<AF_UNIX> sockets and SysV systems where it uses the C<connld> STREAMS module.

=item $passer_fh = AnyEvent::FDpasser::fdpasser_accept($listener_fh)

Given a listener filehandle created with L<AnyEvent::FDpasser::fdpasser_server>, this function accepts and creates a new filehandle suitable for creating an FDpasser object. It is portable between BSD systems where it uses the socket C<accept(2)> system call and SysV systems where it uses C<ioctl(I_RECVFD)>.

=item $passer_fh = AnyEvent::FDpasser::fdpasser_connect($path)

This function connects to a listening node on the filesystem created with L<AnyEvent::FDpasser::fdpasser_server> and returns a new filehandle suitable for creating an FDpasser object. It is portable between BSD systems where it uses the socket C<connect(2)> system call and SysV systems where it C<open()>s a mounted stream.

=back




=head1 NOTES

=head2 Userspace buffers

Because the underlying operations only transfer file descriptors, it is undefined whether any data in userspace buffers like IO::Handle or AnyEvent::Handle will have been written to the file descriptor at the time it is transfered. You should always flush userspace data before you initiate a transfer, and not write more data afterwards. This is why the synopsis uses C<syswrite> to bypass userspace buffers.

You should remove all IO watchers associated with the descriptor before initiating the transfer because after the descriptor is transfered it will be closed and watchers should always be destroyed before closing their respective filehandles. Also, if data comes in and is read by a read watcher before the descriptor is transfered, that data will be lost.


=head2 Forking

This module itself never calls C<fork()>, but many use-cases of this module involve the application program forking. All the usual things you must worry about when forking an AnyEvent application also apply to this module. In particular, you should ensure that you fork before sending or receiving any descriptors because these operations create AnyEvent watchers and doing so will start the event loop. Since both the parent and child require a running event loop to drive FDpasser, in this configuration the event loop must be reset in the child process (see the AnyEvent documentation).

Note that creating a passer object before forking is fine since doing this doesn't install any AnyEvent watchers. Also, using the filesystem with C<AF_UNIX> sockets (or more portably, C<fdpasser_server>, C<fdpasser_accept>, and C<fdpasser_connect>) obviates the need to worry about forking.


=head2 Control channels

A useful design is to have a "control channel" associated with each passer that sends over data related to file descriptors being passed. As long as the control channel is a synchronised and ordered queue of messages, each message can indicate how many descriptors it is sending along on the FDpasser channel.

With both the BSD and SysV APIs it is possible to use the passer filehandle to transfer control data but this module does not support this in order to keep the API simple. However, instead you can use a separate socket connection as your control channel. How to synchronize passers and control channels? One way is to connect to a passer server and pass the control channel socket in as the first file descriptor.


=head2 Portability

In order to use the SysV interface, set the C<FDPASSER_SYSV> environment variable when running C<Makefile.PL>:

    $ FDPASSER_SYSV=1 perl Makefile.PL

Currently the default is to always use the BSD interface. It will attempt to figure out which interface is appropriate (BSD4.4 or BSD4.3). Currently Solaris uses 4.3 and everything else uses 4.4. Patches and/or portability reports are welcome.



=head1 FULL DESCRIPTOR TABLES

Any system call that creates new descriptors in your process can fail because your process has exceed its NOFILE resource limit. Also, it can fail because the system has run out of resources and can't handle new files or (more likely on modern systems) it has hit an artificial kernel-imposed limit like C<kern.maxfiles> on BSD.

In order to pass a file descriptor between processes, a new descriptor needs to be allocated in the receiving process. Therefore, the C<recvmsg> and C<ioctl> system calls used to implement descriptor passing can fail unexpectedly. Failing to create a descriptor is especially bad when transfering descriptors since the outcome is not well specified. Linux doesn't even mention this possible failure mode in the recvmsg() man page. BSD manuals indicate that EMSGSIZE will be returned and any descriptors in transit will be closed. If a descriptor is closed it can never be delivered to the application, even if the full descriptor table problem clears up.

So what should we do? We could silently ignore it when a descriptor fails to transfer, but then we run the risk of desynchronising the descriptor stream. Another possibility is indicating to the application that this descriptor has failed to transfer and is now lost forever. Unfortunately this complicates the error handling an application must do, especially if the descriptor is linked to other descriptors which must then be received and (if they make it) closed. Finally, we could just give up, call the on_error callback, destory the passer object and punt the problem back to the application.

None of the above "solutions" are very appealing so this module uses a trick known as the "close-dup slot reservation" trick. Actually I just made that name up now but it sounds pretty cool don't you think? The idea is that when the passer object is created, we C<dup> a file descriptor and store it in the object. This module creates a pipe when the passer object is made, closes one side of the pipe and keeps the other around indefinitely. This "sentinel" descriptor exists solely to take up an entry in our descriptor table: we will never write to it, read from it, or poll it.

When it comes time to receive a descriptor, we close the sentinel descriptor, receive the descriptor, and then attempt to dup another descriptor. Because we just cleared a descriptor entry, there should always be a free descriptor to create.

After we have received the descriptor, we attempt to C<dup> another descriptor. If that fails, we stop trying to receive any further descriptors and instead try again at regular intervals to C<dup>. Hopefully eventually the full descriptor table issue will clear up and we will be able to resume receiving descriptors.

Note that a descriptor could be created between closing and receiving if your program uses asynchronous signal handlers or threads that create descriptors, so don't do that. Signal handlers that run synchronously (like normal AnyEvent signal watchers) are fine though.

This trick is similar to a trick described in Marc Lehmann's libev POD document, section "special problem of accept()ing when you can't," although the purpose of employing the trick in this module is somewhat different.




=head1 TESTS AND SYSTEM ASSUMPTIONS

All the following tests should work with BSD4.4, BSD4.3, and SysV interfaces (where available).


=head2 Bidirectional

A passer is bidirectional and can be used to both send and receive descriptors, even simultaneously.

There are tests (basic_socketpair.t and basic_filesystem.t) to verify this.


=head2 Non-blocking

A process may initiate push_recv_fh on a passer and this process will not block while it is waiting for the other end to call push_send_fh (and vice versa).

There are tests (recv_before_send.t and send_before_recv.t) to verify this.


=head2 FIFO ordering

The order descriptors are sent with push_send_fh is the same order that they are received on at the other end with push_recv_fh.

There is a test (buffer_exercise.t) to verify this and some other basic buffering properties.


=head2 Preserves blocking status

After a fork, the non-blocking status of a descriptor is preserved so if you are doing a socketpair followed by a fork it is acceptable to set the non-blocking status of both descriptors in the parent.

Also, the non-blocking status of a descriptor passed with this module is preserved after it is passed so it is not necessary to reset nonblocking status on descriptors.

There is a test (non_blocking_fhs.t) to verify this and some other assumptions for any given system.


=head2 Passing passers

Passing a descriptor and then using this descriptor as an argument to the existing_fh mode of this module to construct another passer is supported.

There is a test (send_passer_over_passer.t) to verify this assumption for any given system.


=head2 Descriptor table full

Even when the descriptor table fills up intermittently, no descriptors being passed should be lost.

There is a test (full_descriptor_table.t) to verify this.






=head1 SEE ALSO

L<The AnyEvent::FDpasser github repo|https://github.com/hoytech/AnyEvent-FDpasser>

This module gets its name from L<File::FDpasser> which does roughly the same thing as this module except this module provides a non-blocking interface, buffers the sending and receiving of descriptors, doesn't lose descriptors in the event of a full descriptor table, and doesn't print un-silenceable messages to stderr from the XS code.

L<Socket::PassAccessRights> is another module similar to File::FDpasser. It supports BSD4.3 and BSD4.4 interfaces.

L<Sprocket::Util::FDpasser> is an example of a non-blocking interface to File::FDpasser. It is based on L<POE> whereas this module is (obviously) based on AnyEvent.

A related module is L<Socket::MsgHdr> which provides complete control over ancillary data construction and parsing and is therefore useful for more than just passing descriptors. However, this module does not provide a non-blocking interface or buffering, and only supports the BSD4.4 interface (so it doesn't work for passing descriptors on Solaris).



=head1 BUGS

This module doesn't support windows. Theoretically windows support could be added with some annoying combination of C<DuplicateHandle> and C<WSADuplicateSocket> but I don't care enough to implement it at this time.

If there are multiple outstanding filehandles to be sent, for performance reasons this module could (on BSD4.4 systems) batch them together into one C<cmsg> and then execute one C<sendmsg()> system call. Unfortunately, that would make the close-dup trick less efficient. Maybe there is a sweet spot?

It would be nice to auto-detect the best interface (BSD4.4/BSD4.3/SysV) to use for a given system.




=head1 AUTHOR

Doug Hoyte, C<< <doug@hcsw.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012 Doug Hoyte.

This module is licensed under the same terms as perl itself.

=cut

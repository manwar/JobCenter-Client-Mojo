package JobCenter::Client::Mojo;
use Mojo::Base -base;

our $VERSION = '0.17'; # VERSION

#
# Mojo's default reactor uses EV, and EV does not play nice with signals
# without some handholding. We either can try to detect EV and do the
# handholding, or try to prevent Mojo using EV.
#
BEGIN {
	$ENV{'MOJO_REACTOR'} = 'Mojo::Reactor::Poll' unless $ENV{'MOJO_REACTOR'};
}
# more Mojolicious
use Mojo::IOLoop;
use Mojo::Log;

# standard perl
use Carp qw(croak);
use Cwd qw(realpath);
use Encode qw(encode_utf8 decode_utf8);
use File::Basename;
use FindBin;
use Sys::Hostname;

# from cpan
use JSON::RPC2::TwoWay;
# JSON::RPC2::TwoWay depends on JSON::MaybeXS anyways, so it can be used here
# without adding another dependency
use JSON::MaybeXS qw(decode_json encode_json);
use MojoX::NetstringStream 0.04;

has [qw(
	actions address auth conn daemon debug jobs json log method 
	port rpc timeout tls token who
)];

sub new {
	my ($class, %args) = @_;
	my $self = $class->SUPER::new();

	my $address = $args{address} // '127.0.0.1';
	my $debug = $args{debug} // 0; # or 1?
	my $json = $args{json} // 1;
	my $log = $args{log} // Mojo::Log->new(level => ($debug) ? 'debug' : 'info');
	my $method = $args{method} // 'password';
	my $port = $args{port} // 6522;
	my $timeout = $args{timeout} // 60;
	my $tls = $args{tls} // 0;
	my $tls_ca = $args{tls_ca};
	my $tls_cert = $args{tls_cert};
	my $tls_key = $args{tls_key};
	my $token = $args{token} or croak 'no token?';
	my $who = $args{who} or croak 'no who?';

	my $rpc = JSON::RPC2::TwoWay->new(debug => $debug) or croak 'no rpc?';
	$rpc->register('greetings', sub { $self->rpc_greetings(@_) }, notification => 1);
	$rpc->register('job_done', sub { $self->rpc_job_done(@_) }, notification => 1);
	$rpc->register('ping', sub { $self->rpc_ping(@_) });
	$rpc->register('task_ready', sub { $self->rpc_task_ready(@_) }, notification => 1);

	my $clarg = {
		address => $address,
		port => $port,
		tls => $tls,
	};
	$clarg->{tls_ca} = $tls_ca if $tls_ca;
	$clarg->{tls_cert} = $tls_cert if $tls_cert;
	$clarg->{tls_key} = $tls_key if $tls_key;

	my $clientid = Mojo::IOLoop->client(
		$clarg => sub {
		my ($loop, $err, $stream) = @_;
		if ($err) {
			$err =~ s/\n$//s;
			$log->info('connection to API failed: ' . $err);
			$self->{auth} = 0;
			return;
		}
		my $ns = MojoX::NetstringStream->new(stream => $stream);
		my $conn = $rpc->newconnection(
			owner => $self,
			write => sub { $ns->write(@_) },
		);
		$self->{conn} = $conn;
		$ns->on(chunk => sub {
			my ($ns2, $chunk) = @_;
			#say 'got chunk: ', $chunk;
			my @err = $conn->handle($chunk);
			$log->debug('chunk handler: ' . join(' ', grep defined, @err)) if @err;
			$ns->close if $err[0];
		});
		$ns->on(close => sub {
			$conn->close;
			$log->info('connection to API closed');
			Mojo::IOLoop->stop;
			#exit(1);
		});
	});

	$self->{actions} = {};
	$self->{address} = $address;
	$self->{clientid} = $clientid;
	$self->{daemon} = $args{daemon} // 0;
	$self->{debug} = $args{debug} // 1;
	$self->{jobs} = {};
	$self->{json} = $json;
	$self->{log} = $log;
	$self->{method} = $method;
	$self->{port} = $port;
	$self->{rpc} = $rpc;
	$self->{timeout} = $timeout;
	$self->{tls} = $tls;
	$self->{tls_ca} = $tls_ca;
	$self->{tls_cert} = $tls_cert;
	$self->{tls_key} = $tls_key;
	$self->{token} = $token;
	$self->{who} = $who;

	# handle timeout?
	my $tmr = Mojo::IOLoop->timer($timeout => sub {
		my $loop = shift;
		$log->error('timeout wating for greeting');
		$loop->remove($clientid);
		$self->{auth} = 0;
	});

	$self->log->debug('starting handshake');
	Mojo::IOLoop->one_tick while !defined $self->{auth};
	$self->log->debug('done with handhake?');

	Mojo::IOLoop->remove($tmr);
	return $self if $self->{auth};
	return;
}

sub rpc_greetings {
	my ($self, $c, $i) = @_;
	Mojo::IOLoop->delay->steps(
		sub {
			my $d = shift;
			die "wrong api version $i->{version} (expected 1.1)" unless $i->{version} eq '1.1';
			$self->log->info('got greeting from ' . $i->{who});
			$c->call('hello', {who => $self->who, method => $self->method, token => $self->token}, $d->begin(0));
		},
		sub {
			my ($d, $e, $r) = @_;
			my $w;
			#say 'hello returned: ', Dumper(\@_);
			die "hello returned error $e->{message} ($e->{code})" if $e;
			die 'no results from hello?' unless $r;
			($r, $w) = @$r;
			if ($r) {
				$self->log->info("hello returned: $r, $w");
				$self->{auth} = 1;
			} else {
				$self->log->error('hello failed: ' . ($w // ''));
				$self->{auth} = 0; # defined but false
			}
		}
	)->catch(sub {
		my ($delay, $err) = @_;
		$self->log->error('something went wrong in handshake: ' . $err);
		$self->{auth} = '';
	});
}

sub rpc_job_done {
	my ($self, $conn, $i) = @_;
	my $job_id = $i->{job_id};
	my $outargs = $i->{outargs};
	my $outargsj = encode_json($outargs);
	$outargs = $outargsj if $self->{json};
	$outargsj = decode_utf8($outargsj); # for debug printing
	my $callcb = delete $self->{jobs}->{$job_id};
	if ($callcb) {
		$self->log->debug("got job_done: for job_id  $job_id result: $outargsj");
		local $@;
		eval {
			$callcb->($job_id, $outargs);
		};
		$self->log->info("got $@ calling callback");
	} else {
		$self->log->debug("got job_done for unknown job $job_id result:	 $outargsj");
	}
}

sub call {
	my ($self, %args) = @_;
	my ($done, $job_id, $outargs);
	$args{cb1} = sub {
		($job_id) = @_;
		$done++ unless $job_id;
	};
	$args{cb2} = sub {
		($job_id, $outargs) = @_;
		$done++;
	};
	$self->call_nb(%args);

	Mojo::IOLoop->one_tick while !$done;

	return $job_id, $outargs;
}

sub call_nb {
	my ($self, %args) = @_;
	my $wfname = $args{wfname} or die 'no workflowname?';
	my $vtag = $args{vtag};
	my $inargs = $args{inargs} // '{}';
	my $callcb = $args{cb1} // die 'no call callback?';
	my $rescb = $args{cb2} // die 'no result callback?';
	my $timeout = $args{timeout} // $self->timeout * 5; # a bit hackish..
	my $inargsj;

	if ($self->{json}) {
		$inargsj = $inargs;
		$inargs = decode_json($inargs);
		croak 'inargs is not a json object' unless ref $inargs eq 'HASH';
	} else {
		croak 'inargs should be a hashref' unless ref $inargs eq 'HASH';
		# test encoding
		$inargsj = encode_json($inargs);
	}

	$inargsj = decode_utf8($inargsj);
	$self->log->debug("calling $wfname with '" . $inargsj . "'" . (($vtag) ? " (vtag $vtag)" : ''));

	my $delay = Mojo::IOLoop->delay->steps(
		sub {
			my $d = shift;
			$self->conn->call('create_job', {
				wfname => $wfname,
				vtag => $vtag,
				inargs => $inargs,
				timeout => $timeout,
			}, $d->begin(0));
		},
		sub {
			my ($d, $e, $r) = @_;
			if ($e) {
				$self->log->error("create_job returned error: $e->{message} ($e->{code}");
				$callcb->(undef, "$e->{message} ($e->{code}");
				return;
			}
			my ($job_id, $msg) = @$r; # fixme: check for arrayref?
			if ($msg) {
				$self->log->error("create_job returned error: $msg");
				$callcb->(undef, $msg);
				return;
			}
			if ($job_id) {
				$self->log->debug("create_job returned job_id: $job_id");
				$self->jobs->{$job_id} = $rescb;
				$callcb->($job_id);
			}
		}
	)->catch(sub {
		my ($delay, $err) = @_;
		$self->log->error("Something went wrong in call_nb: $err");
		$callcb->(undef, $err);
	});
}

sub get_job_status {
	my ($self, $job_id) = @_;
	croak('no job_id?') unless $job_id;

	my ($done, $job_id2, $outargs);
	Mojo::IOLoop->delay->steps(
	sub {
		my $d = shift;
		# fixme: check results?
		$self->conn->call('get_job_status', { job_id => $job_id }, $d->begin(0));
	},
	sub {
		#say 'call returned: ', Dumper(\@_);
		my ($d, $e, $r) = @_;
		if ($e) {
			$self->log->debug("get_job_status got error $e");
			$outargs = $e;
			$done++;
			return;
		}
		($job_id2, $outargs) = @$r;
		#$self->log->debug("get_job_satus got job_id: $res msg: $msg");
		$done++;
	})->catch(sub {
		my ($d, $err) = @_;
		$self->log->debug("something went wrong with get_job_status: $err");
		$done++;
	});

	Mojo::IOLoop->one_tick while !$done;

	return $job_id, $outargs;
}

sub ping {
	my ($self, $timeout) = @_;

	$timeout //= $self->timeout;
	my ($done, $ret);

	Mojo::IOLoop->timer($timeout => sub {
		$done++;
	});

	$self->conn->call('ping', {}, sub {
		my ($e, $r) = @_;
		if (not $e and $r and $r =~ /pong/) {
			$ret = 1;
		} else {
			%$self = ();
		}
		$done++;
	});

	Mojo::IOLoop->one_tick while !$done;
	return $ret;
}

sub work {
	my ($self) = @_;
	if ($self->daemon) {
		_daemonize();
	}

	$self->log->debug('JobCenter::Client::Mojo starting work');
	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
	$self->log->debug('JobCenter::Client::Mojo done?');

	return 0;
}

sub announce {
	my ($self, %args) = @_;
	my $actionname = $args{actionname} or croak 'no actionname?';
	my $cb = $args{cb} or croak 'no cb?';
	my $async = $args{async} // 0;
	my $slots = $args{slots} // 1;
	my $host = hostname;
	my $workername = $args{workername} // "$self->{who} $host $0 $$";
	
	croak "already have action $actionname" if $self->actions->{$actionname};
	
	my $err;
	Mojo::IOLoop->delay->steps(
	sub {
		my $d = shift;
		# fixme: check results?
		$self->conn->call('announce', {
				 workername => $workername,
				 actionname => $actionname,
				 slots => $slots
			}, $d->begin(0));
	},
	sub {
		#say 'call returned: ', Dumper(\@_);
		my ($d, $e, $r) = @_;
		if ($e) {
			$self->log->debug("announce got error $e");
			$err = $e;
		}
		my ($res, $msg) = @$r;
		$self->log->debug("announce got res: $res msg: $msg");
		$self->actions->{$actionname} = { cb => $cb, async => $async, slots => $slots } if $res;
		$err = $msg unless $res;
	})->catch(sub {
		my $d;
		($d, $err) = @_;
		$self->log->debug("something went wrong with announce: $err");
	})->wait();

	return $err;
}

sub rpc_ping {
	my ($self, $c, $i, $rpccb) = @_;
	return 'pong!';
}

sub rpc_task_ready {
	#say 'got task_ready: ', Dumper(\@_);
	my ($self, $c, $i) = @_;
	my $actionname = $i->{actionname};
	my $job_id = $i->{job_id};
	my $action = $self->actions->{$actionname};
	unless ($action) {
		$self->log->info("got task_ready for unknown action $actionname");
		return;
	}

	$self->log->debug("got task_ready for $actionname job_id $job_id calling get_task");
	Mojo::IOLoop->delay->steps(sub {
		my $d = shift;
		$c->call('get_task', {actionname => $actionname, job_id => $job_id}, $d->begin(0));
	},
	sub {
		my ($d, $e, $r) = @_;
		#say 'get_task returned: ', Dumper(\@_);
		if ($e) {
			$$self->log->debug("got $e->{message} ($e->{code}) calling get_task");
		}
		unless ($r) {
			$self->log->debug('no task for get_task');
			return;
		}
		my ($cookie, $inargs);
		($job_id, $cookie, $inargs) = @$r;
		unless ($cookie) {
			$self->log->debug('aaah? no cookie? (get_task)');
			return;
		}
		local $@;
		if ($action->{async}) {
			eval {
				$action->{cb}->($job_id, $inargs, sub {
					$c->notify('task_done', { cookie => $cookie, outargs => $_[0] });
				});
			};
			$c->notify('task_done', { cookie => $cookie, outargs => { error => $@ } }) if $@;
		} else { 
			my $outargs = eval { $action->{cb}->($job_id, $inargs) };
			$outargs = { error => $@ } if $@;
			$c->notify('task_done', { cookie => $cookie, outargs => $outargs });
		}
	});
}

# copied from Mojo::Server
sub _daemonize {
	use POSIX;

	# Fork and kill parent
	die "Can't fork: $!" unless defined(my $pid = fork);
	exit 0 if $pid;
	POSIX::setsid or die "Can't start a new session: $!";

	# Close filehandles
	open STDIN,  '</dev/null';
	open STDOUT, '>/dev/null';
	open STDERR, '>&STDOUT';
}

1;

=encoding utf8

=head1 NAME

JobCenter::Client::Mojo - JobCenter JSON-RPC 2.0 Api client using Mojo.

=head1 SYNOPSIS

  use JobCenter::Client::Mojo;

   my $client = JobCenter::Client::Mojo->new(
     address => ...
     port => ...
     who => ...
     token => ...
   );

   my ($job_id, $outargs) = $client->call(
     wfname => 'test',
     inargs => { test => 'test' },
   );

=head1 DESCRIPTION

L<JobCenter::Client::Mojo> is a class to build a client to connect to the
JSON-RPC 2.0 Api of the L<JobCenter> workflow engine.  The client can be
used to create and inspect jobs as well as for providing 'worker' services
to the JobCenter.

=head1 METHODS

=head2 new

$client = JobCenter::Client::Mojo->new(%arguments);

Class method that returns a new JobCenter::Client::Mojo object.

Valid arguments are:

=over 4

=item - address: address of the Api.

(default: 127.0.0.1)

=item - port: port of the Api

(default 6522)

=item - tls: connect using tls

(default false)

=item - tls_ca: verify server using ca

(default undef)

=item - tls_key: private client key

(default undef)

=item - tls_ca: public client certificate

(default undef)

=item - who: who to authenticate as.

(required)

=item - method: how to authenticate.

(default: password)

=item - token: token to authenticate with.

(required)

=item - debug: when true prints debugging using L<Mojo::Log>

(default: false)

=item - json: flag wether input is json or perl.

when true expects the inargs to be valid json, when false a perl hashref is
expected and json encoded.  (default true)

=item - log: L<Mojo::Log> object to use

(per default a new L<Mojo::Log> object is created)

=item - timeout: how long to wait for operations to complete

(default 60 seconds)

=back

=head2 call

($job_id, $result) = $client->call(%args);

Creates a new L<JobCenter> job and waits for the results.  Throws an error
if somethings goes wrong immediately.  Errors encountered during later
processing are returned as a L<JobCenter> error object.

Valid arguments are:

=over 4

=item - wfname: name of the workflow to call (required)

=item - inargs: input arguments for the workflow (if any)

=item - vtag: version tag of the workflow to use (optional)

=item - timeout: wait this many seconds for the job to finish
(optional, defaults to 5 minutes)

=back

=head2 call_nb

$job_id = $client->call_nb(%args);

Creates a new L<JobCenter> job and call the provided callback on completion
of the job.  Throws an error if somethings goes wrong immediately.  Errors
encountered during later processing are returned as a L<JobCenter> error
object to the callback.

Valid arguments are those for L<call> and:

=over 4

=item - cb1: coderef to the callback to call on job creation (requird)

( cb1 => sub { ($job_id, $err) = @_; ... } )

If job_id is undefined the job was not created, the error is then returned
as the second return value.

=item - cb2: coderef to the callback to call on job completion (requird)

( cb2 => sub { ($job_id, $outargs) = @_; ... } )

=back

=head2 get_job_status

($job_id, $result) = $client->get_job_status($job_id);

Retrieves the status for the given $job_id.  If the job_id does not exist
then the returned $job_id will be undefined and $result will be an error
message.  If the job has not finished executing then both $job_id and
$result will be undefined.  Otherwise the $result will contain the result of
the job.  (Which may be a JobCenter error object)

=head2 ping

$status = $client->ping($timeout);

Tries to ping the JobCenter API. On success return true. On failure returns
the undefined value, after that the client object should be undefined.

=head2 announce

Announces the capability to do an action to the Api.  The provided callback
will be called when there is a task to be performed.  Returns an error when
there was a problem announcing the action.

  my $err = $client->announce(
    workername => 'me',
    actionname => 'do',
    slots => 1
    cb => sub { ... },
  );
  die "could not announce $actionname?: $err" if $err;

See L<jcworker> for an example.

Valid arguments are:

=over 4

=item - workername: name of the worker

(optional, defaults to client->who, processname and processid)

=item - actionname: name of the action

(required)

=item - cb: callback to be called for the action

(required)

=item - async: if true then the callback gets passed another callback as the
last argument that is to be called on completion of the task.

(optional, default false)

=item - slots: the amount of tasks the worker is able to process in parallel
for this action.

(optional, default 1)

=back

=head2 work

Starts the L<Mojo::IOLoop>.

=head1 SEE ALSO

=over 4

=item *

L<Mojo::IOLoop>, L<Mojo::IOLoop::Stream>, L<http://mojolicious.org>: the L<Mojolicious> Web framework

=item *

L<examples/jcclient>, L<examples/jcworker>

=item *

=back

L<https://github.com/a6502/JobCenter>: JobCenter Orchestration Engine

=head1 ACKNOWLEDGEMENT

This software has been developed with support from L<STRATO|https://www.strato.com/>.
In German: Diese Software wurde mit Unterstützung von L<STRATO|https://www.strato.de/> entwickelt.

=head1 AUTHORS

=over 4

=item *

Wieger Opmeer <wiegerop@cpan.org>

=back

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2017 by Wieger Opmeer.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

1;

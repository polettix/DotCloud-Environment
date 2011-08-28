package DotCloud::Environment;

# ABSTRACT: easy handling of environment in dotcloud

use strict;
use warnings;
use Carp;
use English qw( -no_match_vars );
use Storable qw< dclone >;

our $main_file_path = '/home/dotcloud/environment.json';
my @application_keys = qw< environment project service_id service_name >;

sub new {
   my $package = shift;
   my %params = (@_ > 0 && ref $_[0]) ? %{ $_[0] } : @_;
   my $self = bless { _params => \%params, _envfor => {} }, $package;
   $self->load() unless $params{no_load};
   return $self;
}

sub _serialize_multiple {
   my $self = shift;
   my $serializer = shift;
   my @applications = @_ > 0 ? @_ : $self->application_names();
   my %retval = map { $_ => $serializer->($self->_recompact($_))} @applications;
   return %retval if wantarray();
   return \%retval;
}

sub as_json {
   my $self = shift;
   require JSON;
   return $self->_serialize_multiple(\&JSON::to_json, @_);
}

sub as_yaml {
   my $self = shift;
   require YAML;
   return $self->_serialize_multiple(\&YAML::Dump, @_);
}

sub load {
   my $self = shift;
   defined(my $env= $self->_get_environment(@_))
      or croak 'no suitable environment found';
   if ($env =~ /\A \s* {/mxs) {
      $self->merge_json($env);
   }
   else {
      $self->merge_yaml($env);
   }
   return $self;
}

sub _recompact {
   my ($self, $application) = @_;
   my $hash = $self->application($application);
   my %retval = map { 'DOTCLOUD_' . uc($_) => $hash->{$_} } @application_keys;
   while (my ($name, $service) = each %{$hash->{services}}) {
      $name = uc($name);
      my $type = uc($service->{type});
      while (my ($varname, $value) = each %{$service->{vars}}) {
         my $key = join '_', 'DOTCLOUD', $name, $type, uc($varname);
         $retval{$key} = $value;
      }
   }
   return \%retval;
}

sub _merge {
   my ($self, $hash) = @_;

   my %flag_for = map { $_ => 1 } @application_keys;

   my %data_for;
   while (my ($name, $value) = each %$hash) {
      my ($key) = $name =~ m{\A DOTCLOUD_ (.*) }mxs
         or next;
      $key = lc $key;
      if ($flag_for{$key}) {
         $data_for{$key} = $value;
      }
      else {
         my ($service, $type, $varname)
            = $key =~ m{\A (.*) _ ([^_]+) _ ([^_]+) \z}mxs;
         $data_for{services}{$service}{type} = $type;
         $data_for{services}{$service}{vars}{$varname} = $value;
      }
   }
   
   $self->{_envfor}{$data_for{project}} = \%data_for;

   return $self;
}

sub merge_json {
   my ($self, $env) = @_;
   require JSON;
   return $self->_merge(JSON::from_json($env));
}

sub merge_yaml {
   my ($self, $env) = @_;
   require YAML;
   return $self->_merge(YAML::Load($env));
}

sub _slurp {
   my ($filename) = @_;
   open my $fh, '<:encoding(utf8)', $filename
      or croak "open('$filename'): $OS_ERROR";
   local $/;
   my $text = <$fh>;
   close $fh;
   return $text;
}

sub _to_chars {
   my ($string) = @_;
   return $string if utf8::is_utf8($string);
   require Encode;
   return Encode::decode('utf8', $string);
}

sub _get_environment {
   my $self = shift;
   my %params = (@_ > 0 && ref $_[0]) ? %{ $_[0] } : @_;
   return _to_chars($params{environment_string})
      if exists $params{environment_string};
   return _slurp($params{environment_file})
      if exists $params{environment_file};
   return _to_chars($self->{_params}{environment_string})
      if exists $self->{_params}{environment_string};
   return _slurp($self->{_params}{environment_file})
      if exists $self->{_params}{environment_file};
   return _slurp($ENV{DOTCLOUD_ENVIRONMENT})
      if exists $ENV{DOTCLOUD_ENVIRONMENT};
   return _slurp($main_file_path)
      if -e $main_file_path;
   return _to_chars($params{fallback_string})
      if exists $params{fallback_string};
   return _slurp($params{fallback_file})
      if exists $params{fallback_file};
   return _to_chars($self->{_params}{fallback_string})
      if exists $self->{_params}{fallback_string};
   return _slurp($self->{_params}{fallback_file})
      if exists $self->{_params}{fallback_file};
   return;
}

sub _dclone {
   return dclone(ref $_[0] ? $_[0] : {@_});
}

sub _dclone_return {
   my $retval = _dclone(@_);
   return $retval unless wantarray();
   return %$retval;
}

sub application_names {
   my $self = shift;
   my @names = keys %{$self->{_envfor}};
   return @names if wantarray();
   return \@names;
}

sub applications {
   my $self = shift;
   return _dclone_return($self->{_envfor});
}

sub application {
   my $self = shift;
   my $application = shift;
   $self->{_envfor}{$application} = _dclone(@_) if @_;
   croak "no application '$application'"
      unless exists $self->{_envfor}{$application};
   _dclone_return($self->{_envfor}{$application});
}

sub _service {
   my ($self, $application, $service);
   return unless exists $self->{_envfor}{$application};
   my $services = $self->{_envfor}{$application}{services};
   return unless exists $services->{$service};
   return $services->{$service};
}


sub service {
   my $self = shift;
   my %params = (@_ > 0 && ref($_[0])) ? %{$_[0]} : @_;

   my $service = $params{service};

   my @found_services;
   my @applications = $service =~ s{\A (.*) \.}{}mxs ? $1
      : exists $params{application} ? $params{application}
      : $self->application_names();
   for my $candidate (@applications) {
      my $services = $self->application($candidate)->{services}; # this croaks
      push @found_services, $services->{$service}
         if exists $services->{$service};
   }

   croak "cannot find requested service"
      if @found_services == 0;
   croak "ambiguous request for service '$service', there are many"
      if @found_services > 1;

   _dclone_return(@found_services);
}

1;
__END__

=head1 SYNOPSIS

   use DotCloud::Environment;

   # get an object, fallback to $path if not in dotCloud deploy
   my $dcenv = DotCloud::Environment->new(fallback_file => $path);

   # you should now which services make part of your stack!
   my $nosqldb_conf = $dcenv->service('nosqldb');
   my $type = $nosqldb_conf->{type}; # e.g. mysql, redis, etc.
   my $vars = $nosqldb_conf->{vars}; # e.g. login, password, host, port...

   # suppose your nosqldb service is redis...
   require Redis;
   my $redis = Redis->new(server => "$vars->{host}:$vars->{port}");
   $redis->auth($vars->{password});

   # another service, similar approach
   my $conf = $dcenv->service('database');
   die 'not MySQL?!?' unless $conf->{type} eq 'mysql';

   my ($host, $port, $user, $pass)
      = @{$conf->{vars}}{qw< host port login password >}
   require DBI;
   my $dbh = DBI->connect("dbi:mysql:host=$host;port=$port;database=wow",
      $user, $pass, {RaiseError => 1});

=head1 DESCRIPTION

L<DotCloud::Environment> is useful when you design applications to be
deployed in the dotCloud platform. It is assumed that you know what
dotCloud is (anyway, see L<http://www.dotcloud.com/>).

In general you will have multiple services in your application, and when
you are in one instance inside dotCloud you can access the configuration
of the relevant ones reading either F</home/dotcloud/environment.yml>
or F</home/dotcloud/environment.json>. For example, this lets your
frontend or backend applications know where the data services are, e.g.
a Redis database or a MySQL one.

This modules serves to two main goals:

=over

=item *

it reads either file to load the configuration of each service, so that
you can access this configuration easily as a hash of hashes;

=item *

it lets you abstract from the assumption that you're actually in a
dotCloud instance, allowing you to use the same interface also in your
development environment.

=back

With respect to the second goal, it should be observed that
most of the times in your development environment you don't have the
same exact situation as in dotCloud, e.g. it's improbable that you have
a F</home/dotcloud> directory around. With this module you can set a
fallback to be used in different ways, e.g.:

=over

=item *

providing a fallback file path to be loaded
if C</home/dotcloud/environment.json> is not found;

=item *

setting up the C<DOTCLOUD_ENVIRONMENT> environment variable to point
to the file to be used;

=back



=method new

   $dcenv = DotCloud::Environment->new(%params);
   $dcenv = DotCloud::Environment->new({%params});

Create a new object. Parameters are:

=over

=item B<< no_load >>

don't attempt to load the configuration

=item B<< environment_string >>

unconditionally use the provided string, ignoring everything else;

=item B<< environment_file >>

unconditionally use the provided file, ignoring everything else;

=item B<< fallback_string >>

use the provided string if other methods fail;

=item B<< fallback_file >>

use the provided file if other methods fail.

=back

Unless C<no_load> is passed and set to true, the object creation also
calls the C</load> method.

Returns the new object or C<croak>s if errors occur.


=method load

   $dcenv->load(%params);
   $dcenv->load({%params});

loads the configuration for an application. The accepted parameters are
C<environment_string>, C<environment_file>, C<fallback_string> and
C<fallback_file> with the same meaning as in the constructor (see L</new>).

The sequence to get the configuration string is the following:

=over

=item B<< environment_string >>

from parameter passed to the method

=item B<< environment_file >>

from parameter passed to the method

=item B<< environment_string >>

from parameter set in the constructor

=item B<< environment_file >>

from parameter set in the constructor

=item B<< DOTCLOUD_ENVIRONMENT >>

environment variable (i.e. C<$ENV{DOTCLOUD_ENVIRONMENT}>)

=item B<< C<$DotCloud::Environment::main_file_path> >>

which defaults to F</home/dotcloud/environment.json> (you SHOULD
NOT change this variable unless you really know what you're doing)

=item B<< fallback_string >>

from parameter passed to the method

=item B<< fallback_file >>

from parameter passed to the method

=item B<< fallback_string >>

from parameter set in the constructor

=item B<< fallback_file >>

from parameter set in the constructor

=back

It is possible to load multiple configuration files from
multiple applications.

Return a reference to the object itself.


=method as_json

   %json_for = $dcenv->as_json();
   $json_for = $dcenv->as_json();

this method rebuilds the JSON representations of all the
applications.

Returns a hash (in list context) or an anonymous hash (in scalar
context) with each application name pointing to the relevant
JSON string.

=method as_yaml

   %yaml_for = $dcenv->as_yaml();
   $yaml_for = $dcenv->as_yaml();

this method rebuilds the YAML representations of all the
applications.

Returns a hash (in list context) or an anonymous hash (in scalar
context) with each application name pointing to the relevant
YAML string.

=method merge_json

   $dcenv->merge_json($json_string);

add (or replace) the configuration of an application, provided as
JSON string. You should not need to do this explicitly, because
this does the same for you with autodetection of the format:

   $dcenv->load(environment_string => $json_or_yaml_string);

Return a reference to the object itself.

=method merge_yaml

   $dcenv->merge_yaml($yaml_string);

add (or replace) the configuration of an application, provided as
YAML string. You should not need to do this explicitly, because
this does the same for you with autodetection of the format:

   $dcenv->load(environment_string => $json_or_yaml_string);

=method application_names

   my @names = $dcenv->application_names();

returns the names of the applications loaded. Generally only one
application will be available, i.e. the one of the stack you're
working with.

=method applications

   my %conf_for = $dcenv->applications();
   my $conf_for = $dcenv->applications();

returns a hash (in list context) or anonymous hash (in scalar context)
with the relevant data of all the applications. Example:

   {
      app1 => {
         project      => 'app1',
         environment  => 'default',
         service_id   => 0,
         service_name => 'www',
         services     => {
            nosqldb => {
               type => 'redis',
               vars => {
                  login    => 'redis',
                  password => 'wafadsfsdfdsfdas',
                  host     => 'data.app1.dotcloud.com',
                  port     => '12345',
               }
            }
            sqldb => {
               type => 'mysql',
               vars => {
                  login    => 'mysql',
                  password => 'wafadsfsdfdsfdas',
                  host     => 'data.app1.dotcloud.com',
                  port     => '54321',
               }
            }
         }
      },
      app2 => {
         # ...
      }
   }

=method application

   my %conf_for = $dcenv->application($appname);
   my $conf_for = $dcenv->application($appname);

returns a hash (in list context) or anonymous hash (in scalar context)
with the relevant data for the requested application. Example:

   {
      project      => 'app1',
      environment  => 'default',
      service_id   => 0,
      service_name => 'www',
      services     => {
         nosqldb => {
            type => 'redis',
            vars => {
               login    => 'redis',
               password => 'wafadsfsdfdsfdas',
               host     => 'data.app1.dotcloud.com',
               port     => '12345',
            }
         }
         sqldb => {
            type => 'mysql',
            vars => {
               login    => 'mysql',
               password => 'wafadsfsdfdsfdas',
               host     => 'data.app1.dotcloud.com',
               port     => '54321',
            }
         }
      }
   }

=method service

   my %conf_for = $dcenv->service(%params); # also with \%params
   my $conf_for = $dcenv->service(%params); # also with \%params

returns a hash (in list context) or anonymous hash (in scalar context)
with the relevant data for the requested service. Example:

   {
      type => 'redis',
      vars => {
         login    => 'redis',
         password => 'wafadsfsdfdsfdas',
         host     => 'data.app1.dotcloud.com',
         port     => '12345',
      }
   }

The parameters are the following:

=over

=item B<< service >>

(B<Required>) the name of the service.

=item B<< application >>

(B<Optional>) the name of the application.

=back

The name of the application is optional because in most cases it can be
omitted, e.g. because there is only one application. The name can be also
provided in the service name, in line with what normally happens in dotCloud
where the complete name of a service is something like C<application.service>.

This is the algorithm:

=over

=item *

if the name of the service is of the form C<application.service>, the
name is split into the two components;

=item *

otherwise, if the application parameter is present it is used

=item *

oterwise the service is searched among all the services of all the
applications.

=back

If exactly one service is found it is returned, otherwise this method
C<croak>s.

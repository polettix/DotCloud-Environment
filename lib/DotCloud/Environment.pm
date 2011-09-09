package DotCloud::Environment;

# ABSTRACT: easy handling of environment in dotcloud

use strict;
use warnings;
use Carp;
use English qw( -no_match_vars );
use Storable qw< dclone >;

use Sub::Exporter -setup =>
  {exports => [qw< dotenv dotvars find_code_dir path_for >],};

our $main_file_path         = '/home/dotcloud/environment.json';
our $main_dotcloud_code_dir = '/home/dotcloud/code';
my @application_keys = qw< environment project service_id service_name >;

### FUNCTIONAL INTERFACE ###

{
   my $default_instance;

   sub dotenv {
      $default_instance ||= __PACKAGE__->new();
      return $default_instance;
   }
}

sub dotvars {
   return dotenv()->service_vars(@_);
}

sub find_code_dir {
   my %params = (@_ > 0 && ref $_[0]) ? %{$_[0]} : @_;
   my $dir = _find_code_dir($params{n});
   if (defined($dir) && $params{unix}) {
      require File::Spec;
      my $reldir = File::Spec->abs2rel($dir);
      my @dirs   = File::Spec->splitdir($reldir);
      $dir = join '/', @dirs;
   } ## end if (defined($dir) && $params...
   return $dir;
} ## end sub find_code_dir

sub path_for {
   my @subs = @_;
   (my $base = find_code_dir(unix => 1)) =~ s{/+\z}{}mxs;
   return map {
      $_ =~ s{\A /+}{}mxs;
      $base . '/' . $_;
   } @subs;
} ## end sub path_for

### OBJECT ORIENTED INTERFACE ###

sub new {
   my $package = shift;
   my %params  = (@_ > 0 && ref $_[0]) ? %{$_[0]} : @_;
   my $self    = bless {
      _params   => \%params,
      _envfor   => {},
      backtrack => 1,          # backtrack by default
   }, $package;
   $self->{backtrack} = $params{backtrack} if exists $params{backtrack};
   $self->load() unless $params{no_load};
   return $self;
} ## end sub new

sub _serialize_multiple {
   my $self         = shift;
   my $serializer   = shift;
   my @applications = @_ > 0 ? @_ : $self->application_names();
   my %retval =
     map { $_ => $serializer->($self->_recompact($_)) } @applications;
   return %retval if wantarray();
   return \%retval;
} ## end sub _serialize_multiple

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
   defined(my $env = $self->_get_environment(@_))
     or croak 'no suitable environment found';
   if ($env =~ /\A \s* {/mxs) {
      $self->merge_json($env);
   }
   else {
      $self->merge_yaml($env);
   }
   return $self;
} ## end sub load

sub _recompact {
   my ($self, $application) = @_;
   my $hash = $self->application($application);
   my %retval =
     map { 'DOTCLOUD_' . uc($_) => $hash->{$_} } @application_keys;
   while (my ($name, $service) = each %{$hash->{services}}) {
      $name = uc($name);
      my $type = uc($service->{type});
      while (my ($varname, $value) = each %{$service->{vars}}) {
         my $key = join '_', 'DOTCLOUD', $name, $type, uc($varname);
         $retval{$key} = $value;
      }
   } ## end while (my ($name, $service...
   return \%retval;
} ## end sub _recompact

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
         my ($service, $type, $varname) =
           $key =~ m{\A (.*) _ ([^_]+) _ ([^_]+) \z}mxs;
         $data_for{services}{$service}{type} = $type;
         $data_for{services}{$service}{vars}{$varname} = $value;
      } ## end else [ if ($flag_for{$key})
   } ## end while (my ($name, $value)...

   $self->{_envfor}{$data_for{project}} = \%data_for;

   return $self;
} ## end sub _merge

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
} ## end sub _slurp

sub _to_chars {
   my ($string) = @_;
   return $string if utf8::is_utf8($string);
   require Encode;
   return Encode::decode('utf8', $string);
} ## end sub _to_chars

sub _get_environment {
   my $self = shift;
   my %params = (@_ > 0 && ref $_[0]) ? %{$_[0]} : @_;
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

   return unless $params{backtrack} || $self->{backtrack};

   # We will backtrack from three starting points:
   # * the "root" directory for the application, i.e
   #   what in dotCloud is /home/dotcloud/code
   # * the current working directory
   # * the directory containing the file that called us
   my $code_dir = find_code_dir(n => 1);

   require Cwd;
   require File::Basename;
   require File::Spec;
   for my $path ($code_dir, Cwd::cwd(),
      File::Basename::dirname((caller())[1]))
   {
      my ($volume, $directories) = File::Spec->splitpath($path, 'no-file');
      my @directories = File::Spec->splitdir($directories);
      while (@directories) {
         my $directories = File::Spec->catdir(@directories);
         for my $format (qw< json yaml >) {
            my $path = File::Spec->catpath($volume, $directories,
               "environment.$format");
            return _slurp($path) if -e $path;
         }
         pop @directories;
      } ## end while (@directories)
   } ## end for my $path ($code_dir...

   return;
} ## end sub _get_environment

sub _find_code_dir {
   return $main_dotcloud_code_dir if -d $main_dotcloud_code_dir;

   my $n = shift || 0;
   require Cwd;
   require File::Basename;
   require File::Spec;
   for my $path (Cwd::cwd(), File::Basename::dirname((caller($n))[1])) {
      my $abspath =
        File::Spec->file_name_is_absolute($path)
        ? $path
        : File::Spec->rel2abs($path);
      my ($volume, $directories) =
        File::Spec->splitpath($abspath, 'no-file');
      my @directories = File::Spec->splitdir($directories);
      while (@directories) {
         my $directories = File::Spec->catdir(@directories);
         my $filepath =
           File::Spec->catpath($volume, $directories, 'dotcloud.yml');
         return File::Spec->catpath($volume, $directories, '')
           if -e $filepath;
         pop @directories;
      } ## end while (@directories)
   } ## end for my $path (Cwd::cwd(...
} ## end sub _find_code_dir

sub _dclone {
   return dclone(ref $_[0] ? $_[0] : {@_});
}

sub _dclone_return {
   my $retval = _dclone(@_);
   return $retval unless wantarray();
   return %$retval;
}

sub application_names {
   my $self  = shift;
   my @names = keys %{$self->{_envfor}};
   return @names if wantarray();
   return \@names;
} ## end sub application_names

sub applications {
   my $self = shift;
   return _dclone_return($self->{_envfor});
}

sub application {
   my $self        = shift;
   my $application = shift;
   $self->{_envfor}{$application} = _dclone(@_) if @_;
   croak "no application '$application'"
     unless exists $self->{_envfor}{$application};
   _dclone_return($self->{_envfor}{$application});
} ## end sub application

sub _service {
   my ($self, $application, $service);
   return unless exists $self->{_envfor}{$application};
   my $services = $self->{_envfor}{$application}{services};
   return unless exists $services->{$service};
   return $services->{$service};
} ## end sub _service

sub service {
   my $self = shift;
   my %params = (@_ > 0 && ref($_[0])) ? %{$_[0]} : @_;

   my $service = $params{service};

   my @found_services;
   my @applications =
       $service =~ s{\A (.*) \.}{}mxs ? $1
     : exists $params{application} ? $params{application}
     :                               $self->application_names();
   for my $candidate (@applications) {
      my $services =
        $self->application($candidate)->{services};    # this croaks
      push @found_services, $services->{$service}
        if exists $services->{$service};
   } ## end for my $candidate (@applications)

   croak "cannot find requested service"
     if @found_services == 0;
   croak "ambiguous request for service '$service', there are many"
     if @found_services > 1;

   _dclone_return(@found_services);
} ## end sub service

sub service_vars {
   my $self    = shift;
   my %params  = (@_ > 0 && ref($_[0])) ? %{$_[0]} : @_;
   my $service = $self->service(@_);
   if (exists $params{list}) {
      my @list   = @{$params{list}};
      my @values = @{$service->{vars}}{@list};
      return @values if wantarray;
      return \@values;
   } ## end if (exists $params{list...
   _dclone_return($service->{vars});
} ## end sub service_vars

1;
__END__

=head1 SYNOPSIS


   # Most typical usage, suppose you have a shared 'lib' directory
   # under the root of your dotCloud directory hierarchy
   use DotCloud::Environment 'path_for';
   use lib path_for('lib');
   use My::Shared::Module; # in your project-root/lib directory

   # Most typical usage when you set a default environment.json file
   # in the root of your project and you need to access the variables
   # of the 'redis' service
   use DotCloud::Environment 'dotvars';
   my $redis_vars = dotvars('redis');

   # Not-very-typical usage examples from now on!

   # get an object, fallback to $path if not in dotCloud deploy
   my $dcenv = DotCloud::Environment->new(fallback_file => $path);

   # you should now which services make part of your stack!
   my $nosqldb_conf = $dcenv->service('nosqldb');
   my $type = $nosqldb_conf->{type}; # e.g. mysql, redis, etc.
   my $vars = $nosqldb_conf->{vars}; # e.g. login, password, host...

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
   my $dbh = DBI->connect("dbi:mysql:host=$host;port=$port;database=db",
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
to the file to be used.

=back

=head2 Suggested/Typical Usage

In order to keep your code clean, you will probably be dividing it
depending on the functional block that will be deployed as a service
in dotCloud. Suppose that you have a frontend service, a backend service
and a database; you probably have the following directory layout:

   project
   +- dotcloud.yml
   +- backend
   |  | ...
   |  +- lib
   |     +- Backend.pm
   +- frontend
   |  | ...
   |  +- lib
   |     +- FrontEnd.pm
   +- lib
      +- Shared.pm

Each service is put into a separate directory and all the code
that they both use (e.g. functions to connect to databases) is put in
a common C<lib> directory.

How should you use DotCloud::Environment?

The main goal is to let it find the right C<environment.json> (or,
equivalently, C<environment.yml>) depending on the environment you
are into. If you are in dotCloud there is actually no problem, because
by default the I<right> C</home/dotcloud/environment.json> file is
selected; for your local development the best thing to do is to put
the configuration file in the project's root directory, which becomes
like this:

   project
   +- dotcloud.yml
   +- backend
   |  | ...
   |  +- lib
   |     +- Backend.pm
   +- frontend
   |  | ...
   |  +- lib
   |     +- FrontEnd.pm
   +- lib
   |  +- Shared.pm
   |
   +- environment.json

Putting the file in that position lets DotCloud::Environment find
it by default when no C</home/dotcloud/environment.json> file (or
the equivalent YAML file) is found in the system. Which hopefully is
the case of your development environment.

In this case, you would have this in each service:

   # -- in BackEnd.pm and FrontEnd.pm --
   use DotCloud::Environment 'path_for';
   use lib path_for('lib');
   use Shared ...;

The function L</path_for> helps you to set up the right path in
C<@INC> so that the module can find the shared code.

In the shared module you can do this:

   # -- in Shared.pm --
   use DotCloud::Environment 'dotenv';

   # ... when you need it...
   my $service = dotenv()->service('service-name');

Most of the time all you need is to access the variables related
to a specific service, so there's a shortcut for this:

   use DotCloud::Environment 'dotvars';
   my $vars = dotvars('service-name');

For example, suppose that you want to implement a function to
connect to a Redis service called C<redisdb>:

   sub get_redis {
      my $vars = dotvars('redisdb');

      require Redis;
      my $redis = Redis->new(server => "$vars->{host}:$vars->{port}");
      $redis->auth($vars->{password});
      return $redis;
   }

Of course you can use C<dotenv>/C<dotvars> directly in C<FrontEnd.pm> and
C<BackEnd.pm>, but you will probably benefit from refactoring your
common code to avoid duplications.


=head1 FUNCTIONS

Nothing is exported by default, but you can import the following
functions. If you need both, you can use the C<:all> tag, e.g.:

   use DotCloud::Environment ':all';

This module uses L<Sub::Exporter> under the hood; this means that
if you're not happy with the name of the imported subroutines you
can provide your own names, e.g.:

   use DotCloud::Environment
      dotvars => { -as => 'dotcloud_variables_for' };
   my $vars = dotcloud_variables_for('my-service');

=head2 B<< dotenv >>

   my $singleton = dotenv();

This function returns a default instance of DotCloud::Environment that
should suit the needs for the typical/suggested usage. Subsequent calls
to the function always return the same object.

It can be useful if you don't want a global variable in your code, e.g.:

   my @application_names = dotenv()->application_names();
   # ...
   my $vars = dotenv()->service_vars('my-sql-db');

=head2 B<< dotvars >>

   my $vars = dotvars('service-name');

This function gets the configuration variables for the provided
service using the default singleton instance. Most of the time this
is exactly what you want, and nothing more.

=head2 B<< find_code_dir >>

   my $code_directory = find_code_dir(%params);

This function tries to find the file F<dotcloud.yml> that
describe the application backtracking from the current working directory and
from the directory containing the file that called us (i.e. what happens to
be C<(caller($n))[1]>).

Parameters:

=over

=item B<< n >>

an integer, defaulting to 0, that tells how to call
C<caller()>. You shouldn't need to set it, anyway.

=item B<< unix >>

when set, the name of the directory will be returned in Unix format, so that
you can use it with C<use lib>. By default the format is the same as the
system.

=back

This should be useful if you want to put a default configuration file there or
if you want to set up a shared library directory. If you are interested into
this feature, anyway, look at L</path_for> which is easier to use.


=head2 B<< path_for >>

   use lib path_for('lib');

This function produces a list of paths that are suitable for
C<use lib>. It uses L</find_code_dir> internally, see it for details.

You should pass a list of subdirectories which will be rebased using
L</find_code_dir> as a parent directory. If you
are actually in the dotCloud enviroment, the example above produces
the path C</home/dotcloud/code/lib>.

Returns a list of Unix paths, one element for each input directory.


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

=item B<< backtrack >>

if nothing works and no fallback is set, look for suitable files
in filesystem.

=back

Unless C<no_load> is passed and set to true, the object creation also
calls the C</load> method.

Returns the new object or C<croak>s if errors occur.


=method load

   $dcenv->load(%params);
   $dcenv->load({%params});

loads the configuration for an application. The accepted parameters are
C<environment_string>, C<environment_file>, C<fallback_string>,
C<fallback_file> and C<backtrack> with the same meaning as in the
constructor (see L</new>).

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

If none of the above works there's still some hope in case there is
option C<backtrack> (or it was specified to the constructor). In this
case, either file is searched recursively starting from the
following directories:

=over

=item *

the one returned by L</find_code_dir> (but as if it were called by
the caller of L</load>, i.e. with a value of C<n> equal to 1)

=item *

the current working directory

=item *

the directory of the file that called us.

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

=method service_vars

   my %vars   = $dcenv->service_vars(%params); # also \%params
   my $vars   = $dcenv->service_vars(%params); # also \%params
   my @values = $dcenv->service_vars(%params); # also \%params
   my $values = $dcenv->service_vars(%params); # also \%params

this method is a shorthand to get the configuration variables of a single
service. Depending on the input, the return value might be structured like
a hash or like an array:

=over

=item B<< service >>

the name of the service, see L</service>

=item B<< application >>

the name of the application, see L</service>

=item B<< list >>

(B<Optional>) if a list is provided, then the values corresponding to each
item in order is returned. This allows writing things like this:

   my ($host, $port, $password) = $dcenv->service_list(
      service => 'nosqldb',
      list => [ qw< host port password > ],
   );

and get directly the values to put into variables. In this case, the return
value can be a list of values or an anonymous array with the values.

If this parameter is not present, the whole name/value hash is returned, either
as a list or as an anonymous hash depending on the context.

=back


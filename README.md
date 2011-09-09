NAME
====

DotCloud::Environment - easy handling of environment in dotcloud

SYNOPSIS
========

    # Most typical usage, suppose you have a shared 'lib' directory
    # under the root of your dotCloud directory hierarchy
    use DotCloud::Environment 'path_for';
    use lib path_for('lib');
    use My::Shared::Module; # in your project-root/lib directory
    
    # Most typical usage when you set a default environment.json file
    # in the root of your project and you need to access the variables
    # of the 'redis' service
    use DotCloud::Environment 'dotenv';
    my $redis_vars = dotenv->service_vars('redis');
    
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


ALL THE REST
============

Want to know more? [See the module's documentation](http://search.cpan.org/perldoc?DotCloud::Environment) to figure out
all the bells and whistles of this module!

Want to install the latest release? [Go fetch it on CPAN](http://search.cpan.org/dist/DotCloud-Environment/).

Want to contribute? [Fork it on GitHub](https://github.com/polettix/DotCloud-Environment).

That's all folks!


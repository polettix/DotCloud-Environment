package Test::DotCloud::Environment;

use strict;
use warnings;
use Carp;
use English qw( -no_match_vars );

use Exporter qw< import >;
use File::Spec::Functions
  qw< rel2abs file_name_is_absolute splitpath splitdir catdir catpath >;

our @EXPORT = qw<
  json_path
  yaml_path
  base_path
  load_json
  load_yaml
  default_data_structure
>;

sub slurp {
   my ($filename) = @_;
   open my $fh, '<:raw', $filename or die "open('$filename'): $OS_ERROR";
   local $/;
   my $text = <$fh>;
   return $text;
} ## end sub slurp
sub load_json { return slurp(shift || json_path()) }
sub load_yaml { return slurp(shift || yaml_path()) }

sub base_path {
   my $file =
     file_name_is_absolute(__FILE__) ? __FILE__ : rel2abs(__FILE__);
   my ($volume, $directories) = splitpath($file);
   my @dirs = splitdir($directories);
   pop @dirs for qw< Environment DotCloud Test lib >;
   $directories = catdir(@dirs);
   return catpath($volume, $directories, '');
} ## end sub base_path

sub path_of {
   my ($filename) = @_;
   my ($volume, $directories) = splitpath(base_path(), 'no_file');
   return catpath($volume, $directories, $filename);
}
sub json_path { return path_of('environment.json') }
sub yaml_path { return path_of('environment.yml') }

sub default_data_structure {
   return {
      'environment'  => 'default',
      'service_name' => 'www',
      'services'     => {
         'nosqldb' => {
            'type' => 'redis',
            'vars' => {
               'password' => 'redis-password-here',
               'url' =>
'redis://redis:redis-password-here@whatever-polettix.dotcloud.com:13749',
               'port'  => '13749',
               'login' => 'redis',
               'host'  => 'whatever-polettix.dotcloud.com'
            }
         },
         'sqldb' => {
            'type' => 'mysql',
            'vars' => {
               'password' => 'mysql-password-here',
               'url' =>
'mysql://root:mysql-password-here@whatever-polettix.dotcloud.com:13747',
               'port'  => '13747',
               'login' => 'root',
               'host'  => 'whatever-polettix.dotcloud.com'
            }
         }
      },
      'project'    => 'whatever',
      'service_id' => '0'
   };

} ## end sub default_data_structure

1;
__END__


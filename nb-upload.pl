#!/usr/bin/perl

use strict;
use warnings;

use WWW::Mechanize;
use File::Basename;
use File::Find;
use NFOStripper;
use Getopt::Long; # to handle arguments
Getopt::Long::Configure ('bundling');
use Config::Simple;

## EDIT BELOW:::: ##

# Handle config.
my $config_file = $ENV{"HOME"}."/.nb-upload.cfg";
my $cfg = new Config::Simple();
$cfg->read($config_file) or die "CONFIG ERROR: ".$cfg->error();

# Ditt brukernavn og passord på NB
my $username = $cfg->param('username');
my $password = $cfg->param('password');

# Hvor torrent som laget blir lagt
my $torrent_file_dir = $cfg->param('torrent_file_dir');

# Hvor torrents blir lastet ned (rTorrent watch dir)
my $torrent_auto_dir = $cfg->param('torrent_auto_dir');

my $site_url = $cfg->param('site_url');


### DO NOT EDIT BELOW THIS LINE UNLESS YOU KNOW WHAT YOU ARE DOING ####
#######################################################################

my $loginurl = $site_url."/takelogin.php";
my $loginref = $site_url."/hei.php";

my $upload_form = $site_url."/upload.php";

my $rnfo = "";
my $nfo_file = "";

my ($scene, $type);
GetOptions ('s|scene' => \$scene, 't|type=s' => \$type) or die("Wrong input");

if ($scene) {
        $scene = "yes";
} else {
		# always scene from usenet
        $scene = "yes";
}

#indata
my ($path, $release, $is_dir);

sub init1 {
	$path = shift;
	$release = basename($path);

	$is_dir = 0;
	$rnfo = "";
	$nfo_file = "";


	if (-d $path) {
	        $is_dir = 1;
	} else {
	        $release =~ m/.*(\..*)$/;
	        $release =~ s/$1//;
	}
}

# Create Mechanize
my $mech = WWW::Mechanize->new();

sub trim($)
{
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

sub login {
        #print "Logging in...\n";
        $mech->default_header('Referer' => $loginref);
        $mech->post( $loginurl, [ "username" => $username, "password" => $password ] );
	if ($mech->uri eq $site_url."/takelogin.php") { die("Login failed"); }
}

sub create_torrent {
        system("buildtorrent -q -p1 -a http://jalla.com $path $torrent_file_dir/$release.torrent");
        return $torrent_file_dir."/".$release.".torrent";
}

sub upload {
        my ($torrent, $nfo, $descr, $type) = @_;
        #print "Uploading torrent...\n";
        $mech->get($upload_form);
        #print $mech->content;
        $mech->submit_form(
                form_name => "upload",
                fields => {
                       MAX_FILE_SIZE => "3000000",
                       file => $torrent,
                       filetype => "2",
                       name => $release,
                       nfo => $nfo,
                       scenerelease => $scene,
                       descr => $descr,
                       type => $type,
                       anonym => "yes"
                }
        );
        unless ($mech->success) {die("Could not upload");}
        #print $mech->content;
	my $uri = $mech->uri();
	if ($uri =~ /details\.php/) {
		return $uri;
	} else {
		if ($mech->content =~ /<h3>Mislykket\sopplasting!<\/h3>\n<p>(.*)<\/p>/) {
			#print $1."\n";
		}
		die("Upload failed!");
	}
}

sub download_torrent {
        my $uri = shift;
        #print "Downloading torrent...\n";
        $mech->get($uri);
        $mech->follow_link( url_regex => qr/download/i );
        unless($mech->success) {die("Could not download torrent");}
        open(my $TORFILE, ">", $torrent_auto_dir."/".$release.".torrent") || die("Could not open file: $!");
        print $TORFILE $mech->content;
        close($TORFILE);
        return $uri;
}

sub strip_nfo {
	if ($_ =~ m/.*\.nzb$/) {
		my $nzb = $File::Find::name;
		system("rm -f $nzb");
	}
	
        if ($_ =~ m/.*\.nfo$/) {
                local $/=undef;
                $nfo_file = $File::Find::name;
                open(my $NFO, $nfo_file) || die("Could not open nfo: $!");
                my $filesize = -s $nfo_file;
                read($NFO, my $rawdata, $filesize);
                close($NFO);

                # NFOStripper Object
                my $snfo = eval { new NFOStripper($rawdata); } or die("Could not strip nfo: $!");

                # Set Image Conversion
                $snfo->ImgOpt(0);

                # Set Code Formatting
                $snfo->FormatOpt(0);

                my $result = $snfo->Strip();

                # Remove add.
                my @nfoarr = split(/\n/, $result);
                $result = "";
                foreach (@nfoarr) {
                       unless ($_ =~ m/Advanced\sNFO\sStripper/) {
                        $result .= $_."\n";
                       }
                }
                $rnfo = $result;
        }
}

sub find_type {
        #my $release = shift;
        if ($type) { return $type }
        if ($release =~ m/(BluRay|Blu-Ray)/i) { return "14" }
        if ($release =~ m/(PDTV|HDTV)\.XviD/i) { return "1" }
        if ($release =~ m/(PDTV|HDTV)\.x264/i) { return "29" }
        if ($release =~ m/S\d.*(PAL|NTSC)\.DVDR/i) { return "27" }
        if ($release =~ m/(PAL|NTSC)\.DVDR/i) { return "20" }
        if ($release =~ m/x264/i) { return "28" }
        if ($release =~ m/XviD/i) { return "25" }
        if ($release =~ m/MP4/i) { return "26" }
        if ($release =~ m/MPEG/i) { return "24" }
		
		# Use if not found.
		return "1";

        die("Unable to detect type, try -t|--type");
}

init1($ARGV[0]);
init2();

sub init2 {
	if($is_dir) {
	        find (\&strip_nfo, $path);
	} else {
		return;
	}

	login();

	my $link = "";
	if($nfo_file && $rnfo) {
	        $link = download_torrent(upload(create_torrent(), $nfo_file, $rnfo, find_type()));
	} else {
	        system("echo \"NFO mangler......\" > $path/mangler.nfo");
			init2();
	}
}

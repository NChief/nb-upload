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
use Convert::Bencode qw(bencode bdecode);
use Log::Log4perl qw(get_logger);
use JSON;

## EDIT BELOW:::: ##

# Handle config.
my $config_file = $ENV{"HOME"}."/.nb-upload.cfg";
my $cfg = new Config::Simple();
$cfg->read($config_file) or die "CONFIG ERROR: ".$cfg->error();

# Initialize perl logging (Not IRC log)
Log::Log4perl::init($config_file);
my $log = Log::Log4perl->get_logger("nb-upload::Log");

# Ditt brukernavn og passord på NB
my $username = $cfg->param('username');
my $password = $cfg->param('password');

# Hvor torrent som laget blir lagt
my $torrent_file_dir = $cfg->param('torrent_file_dir');

# Hvor torrents blir lastet ned (rTorrent watch dir)
my $torrent_auto_dir = $cfg->param('torrent_auto_dir');

my $site_url = $cfg->param('site_url');

my $apikey;
if ($cfg->param('use_tmdb') eq "yes") {
	$apikey = $cfg->param('api_key');
}


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
        $scene = "no";
}

#indata
my ($path, $release, $is_dir);

sub init1 {
	$path = shift;
	$release = basename($path);
	$log->info("Trying to upload $release");

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
my $mech = WWW::Mechanize->new(autocheck => 0);

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
	if ($mech->uri eq $site_url."/takelogin.php") { 
		$log->error("Login failed!");
		die("Login failed"); 
	}
}

sub create_torrent {
	# No need to create, we have one from rtorrent
	my $torfile = $ARGV[0];
	$torfile =~ s/\/\//\//g;
	return $torfile;
}

sub upload {
        my ($torrent, $nfo, $descr, $type) = @_;
		$log->info("Uploading torrent: $torrent");
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
        unless ($mech->success) {
			$log->error("Could not upload: unable to reach site");
			die("Could not upload");
		}
        #print $mech->content;
	my $uri = $mech->uri();
	if ($uri =~ /details\.php/) {
		$log->info("Upload successfull: $uri");
		return $uri;
	} else {
		if ($mech->content =~ /<h3>Mislykket\sopplasting!<\/h3>\n<p>(.*)<\/p>/) {
			$log->error($1);
			#print $1."\n";
		}
		$log->error("Upload failed");
		die("Upload failed!");
	}
}

sub download_torrent {
        my $uri = shift;
		$log->info("Downloading torrent from $uri");
        #print "Downloading torrent...\n";
        $mech->get($uri);
        $mech->follow_link( url_regex => qr/download/i );
        unless($mech->success) {die("Could not download torrent");}
        open(my $TORFILE, ">", $torrent_auto_dir."/".$release.".torrent") || die("Could not open file: $!");
        #print $TORFILE $mech->content;
		my $tfile = fast_resume($mech->content);
		print $TORFILE $tfile;
        close($TORFILE);
		$log->info($torrent_auto_dir."/".$release.".torrent saved.");
        return $uri;
}

sub fast_resume {
	my $t = bdecode(shift);
	
	$log->info("applying fast-resume");
	
	my $d = $path;
	$d =~ s/$release//;
	#$d .= "/" unless $d =~ m#/$#;
	
	#die "No info key.\n" unless ref $t eq "HASH" and exists $t->{info};
	unless (ref $t eq "HASH" and exists $t->{info}) {
		$log->error("fast-resume: No info key");
		die "No info key.\n";
	}
	
	#my $psize = $t->{info}{"piece length"} or die "No piece length key.\n";
	my $psize;
	if($t->{info}{"piece length"}) {
		$psize = $t->{info}{"piece length"};
	} else {
		$log->error("fast-resume: No piece length key");
		die "No piece length key.\n";
	}

	my @files;
	my $tsize = 0;
	if (exists $t->{info}{files}) {
		#print STDERR "Multi file torrent: $t->{info}{name}\n";
		$log->info("Multi file torrent: $t->{info}{name}");
		for (@{$t->{info}{files}}) {
			push @files, join "/", $t->{info}{name},@{$_->{path}};
			$tsize += $_->{length};
		}
	} else {
		#print STDERR "Single file torrent: $t->{info}{name}\n";
		$log->info("Single file torrent: $t->{info}{name}");
		@files = ($t->{info}{name});
		$tsize = $t->{info}{length};
	}
	my $chunks = int(($tsize + $psize - 1) / $psize);
	$log->info("Fast-resume info: Total size: $tsize bytes; $chunks chunks; ", scalar @files, " files.\n");
	
	#die "Inconsistent piece information!\n" if $chunks*20 != length $t->{info}{pieces};
	if ($chunks*20 != length $t->{info}{pieces}) {
		$log->error("Inconsistent piece information!");
		die "Inconsistent piece information!\n";
	}
	
	$t->{libtorrent_resume}{bitfield} = $chunks;
	for (0..$#files) {
		#die "$d$files[$_] not found.\n" unless -e "$d$files[$_]";
		unless (-e "$d$files[$_]") {
			$log->error("$d$files[$_] not found.");
			die "$d$files[$_] not found.\n";
		}
		my $mtime = (stat "$d$files[$_]")[9];
		$t->{libtorrent_resume}{files}[$_] = { priority => 2, mtime => $mtime };
	};
	$log->info("Fast resume applied");
	
	return bencode $t;
}

sub strip_nfo {
	# If rar-file = scene
	#$log->info("Searching for rar-files");
	if ($_ =~ m/.*\.rar$/) {
		$log->info("rar file found, assuming this is scene");
		$scene = "yes";
	}

        if ($_ =~ m/.*\.nfo$/) {
				$log->info("nfo found, stripping..");
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
				if ($cfg->param('use_tmdb') eq "yes") {
					if($result =~ /(tt\d{7})/) {
						$mech->get('http://api.themoviedb.org/2.1/Movie.getImages/en/json/'.$apikey.'/'.$1);
						$log->info("imdb link found, trying to get poster");
						if ($mech->success) {
							#$log->info("");
							my $json = JSON->new->utf8(0)->decode($mech->content);
							$rnfo = '[imgw]'.$json->[0]->{'posters'}[0]->{'image'}->{'url'}.'[/imgw]'."\n";
						} else {
							$log->warn("unable to access themoviedb");
						}
					}
				}
                $rnfo .= $result;
        }
}

sub find_type {
        #my $release = shift;
        if ($type) { return $type }
        #if ($release =~ m/(BluRay|Blu-Ray)/i) { return "19" }
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

if($ARGV[2] eq "NBUL") {
	#$log->info("Script is trying to upload: $ARGV[2]");
	init1($ARGV[1]);
	init2();
}

sub init2 {
	if($is_dir) {
	        find (\&strip_nfo, $path);
	} else {
		$log->error("$path is not a directory");
		return;
	}

	login();

	my $link = "";
	if($nfo_file && $rnfo) {
	        $link = download_torrent(upload(create_torrent(), $nfo_file, $rnfo, find_type()));
			$log->info("Done! - $link");
	} else {
			$log->warn("Nfo not found, making one..");
	        system("echo \"NFO mangler......\" > $path/mangler.nfo");
			init2();
	}
}

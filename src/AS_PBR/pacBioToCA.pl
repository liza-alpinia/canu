#!/usr/bin/perl

#   Copyright (C) 2011, Battelle National Biodefense Institute (BNBI);
#   all rights reserved. Authored by: Sergey Koren
#   
#   This Software was prepared for the Department of Homeland Security
#   (DHS) by the Battelle National Biodefense Institute, LLC (BNBI) as
#   part of contract HSHQDC-07-C-00020 to manage and operate the National
#   Biodefense Analysis and Countermeasures Center (NBACC), a Federally
#   Funded Research and Development Center.
#   
#   Redistribution and use in source and binary forms, with or without
#   modification, are permitted provided that the following conditions are
#   met:
#   
#   * Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#   
#   * Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#   
#   * Neither the name of the Battelle National Biodefense Institute nor
#     the names of its contributors may be used to endorse or promote
#     products derived from this software without specific prior written
#     permission.
#   
#   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
#   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
#   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
#   HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
#   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#   DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#   THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
#   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
###########################################################################
#
#  Read in fragments from fastq-format sequence and quality files,
#  correct to pacbio fragments.
#

use strict;

use Config;  #  for @signame
use FindBin;
use Cwd;
use Carp;
use FileHandle;

use POSIX qw(ceil floor sys_wait_h);

sub makeAbsolute ($) {
    my $val = shift @_;
    if (defined($val) && ($val !~ m!^/!)) {
        $val = "$ENV{'PWD'}/$val";
    }
    return $val;
}

sub getBinDirectory () {
    my $installDir;

    ###
    ### CODE DUPLICATION WITH getBinDirectoryShellCode
    ###

    #  Assume the current binary path is the path to the global CA
    #  install directory.

    #  CODE DUPLICATION!!!

    my @t = split '/', "$FindBin::RealBin";
    pop @t;                      #  bin
    pop @t;                      #  arch, e.g., FreeBSD-amd64
    my $installDir = join '/', @t;  #  path to the assembler
    #  CODE DUPLICATION!!!

    #  Guess what platform we are currently running on.

    my $syst = `uname -s`;    chomp $syst;  #  OS implementation
    my $arch = `uname -m`;    chomp $arch;  #  Hardware platform
    my $name = `uname -n`;    chomp $name;  #  Name of the system

    $arch = "amd64"  if ($arch eq "x86_64");
    $arch = "ppc"    if ($arch eq "Power Macintosh");

    my $path = "$installDir/$syst-$arch/bin";
    return($path);
}

sub runCommand($$) {
   my $dir = shift;
   my $cmd = shift;

   my $t = localtime();
   my $d = time();
   print STDERR "----------------------------------------START $t\n$cmd\n";

   my $rc = 0xffff & system("cd $dir && $cmd");

   $t = localtime();
   print STDERR "----------------------------------------END $t (", time() - $d, " seconds)\n";

   return(0) if ($rc == 0);

   die "Failed to execute $cmd\n";
}

################################################################################

#  Functions for running multiple processes at the same time.

my $numberOfProcesses       = 0;     #  Number of jobs concurrently running
my $numberOfProcessesToWait = 0;     #  Number of jobs we can leave running at exit
my @processQueue            = ();
my @processesRunning        = ();
my $printProcessCommand     = 1;     #  Show commands as they run

sub schedulerSetNumberOfProcesses {
    $numberOfProcesses = shift @_;
}

sub schedulerSubmit {
    chomp @_;
    push @processQueue, @_;
}

sub schedulerForkProcess {
    my $process = shift @_;
    my $pid;

    #  From Programming Perl, page 167
  FORK: {
      if ($pid = fork) {
          # Parent
          #
          return($pid);
     } elsif (defined $pid) {
         # Child
         #
         exec($process);
      } elsif ($! =~ /No more processes/) {
          # EAGIN, supposedly a recoverable fork error
          sleep 1;
          redo FORK;
      } else {
          die "Can't fork: $!\n";
      }
  }
}

sub schedulerReapProcess {
    my $pid = shift @_;

    if (waitpid($pid, &WNOHANG) > 0) {
        return(1);
    } else {
        return(0);
    }
}

sub schedulerRun {
    my @newProcesses;

    #  Reap any processes that have finished
    #
    undef @newProcesses;
    foreach my $i (@processesRunning) {
        if (schedulerReapProcess($i) == 0) {
            push @newProcesses, $i;
        }
    }
    undef @processesRunning;
    @processesRunning = @newProcesses;

    #  Run processes in any available slots
    #
    while ((scalar(@processesRunning) < $numberOfProcesses) &&
           (scalar(@processQueue) > 0)) {
        my $process = shift @processQueue;
        print STDERR "$process\n";
        push @processesRunning, schedulerForkProcess($process);
    }
}

sub schedulerFinish {
    my $child;
    my @newProcesses;
    my $remain;

    my $t = localtime();
    my $d = time();
    print STDERR "----------------------------------------START CONCURRENT $t\n";

    $remain = scalar(@processQueue);

    #  Run all submitted jobs
    #
    while ($remain > 0) {
        schedulerRun();

        $remain = scalar(@processQueue);

        if ($remain > 0) {
            $child = waitpid -1, 0;

            undef @newProcesses;
            foreach my $i (@processesRunning) {
                push @newProcesses, $i if ($child != $i);
            }
            undef @processesRunning;
            @processesRunning = @newProcesses;
        }
    }

    #  Wait for them to finish, if requested
    #
    while (scalar(@processesRunning) > $numberOfProcessesToWait) {
        waitpid(shift @processesRunning, 0);
    }

    $t = localtime();
    print STDERR "----------------------------------------END CONCURRENT $t (", time() - $d, " seconds)\n";
}

################################################################################
my $MIN_FILES_WITHOUT_PARTITIONS = 20;

my $libraryname = undef;
my $specFile = undef;
my $length = 500;
my $threads = 1;
my $repeats = "";
my $fastqFile = undef;
my $correctFile = undef;
my $partitions = 1;
my $sge = undef;
my $submitToGrid = 0;
my $sgeCorrection = undef;
my $consensusConcurrency = 8;
my @fragFiles;
my $cleanup = 1;

my $srcstr;

{
    local $, = " ";
    $srcstr = "$0 @ARGV";
}

my $err = 0;
while (scalar(@ARGV) > 0) {
    my $arg = shift @ARGV;
    if      ($arg eq "-s") {
        $specFile = shift @ARGV;

    } elsif ($arg eq "-length") {
        $length = shift @ARGV;

    } elsif ($arg eq "-repeats") {
       $repeats = shift @ARGV;

    } elsif ($arg eq "-fastq") {
       $fastqFile = shift @ARGV;

    } elsif ($arg eq "-t") {
       $threads = shift @ARGV;
       if ($threads <= 0) { $threads = 1; }

    } elsif ($arg eq "-l") {
       $libraryname = shift @ARGV;

    } elsif ($arg eq "-partitions") {
       $partitions = shift @ARGV;
    
    } elsif ($arg eq "-sge") {
       $sge = shift @ARGV;

    } elsif ($arg eq "-sgeCorrection") {
       $sgeCorrection = shift @ARGV;

    } elsif ($arg eq "-noclean") {
       $cleanup = 0;
    
    } elsif (($arg =~ /\.frg$|frg\.gz$|frg\.bz2$/i) && (-e $arg)) {
       push @fragFiles, $arg;

    } else {
        $err++;
    }
}

if (($err) || (scalar(@fragFiles) == 0) || (!defined($fastqFile)) || (!defined($specFile)) || (!defined($libraryname))) {
    print STDERR "usage: $0 [options] -s spec.file -fastq fastqfile <frg>\n";
    print STDERR "  -length                  Minimum length to keep.\n";
    print STDERR "  -partitions              Number of partitions for consensus\n";
    print STDERR "  -sge                     Submit consensus jobs to the grid\n";
    print STDERR "  -sgeCorrection           Parameters for the correction step for the grid. This should match the threads specified below, for example by using -pe threaded\n";
    print STDERR "  -l libraryname           Name of the library; freeformat text.\n";
    print STDERR "  -t threads               Number of threads to use for correction.\n";
    exit(1);
}

#check for valid parameters for requested partitions and threads
$MIN_FILES_WITHOUT_PARTITIONS += $threads;
my $limit = `ulimit -Sn`;
chomp($limit);
if ($limit - $MIN_FILES_WITHOUT_PARTITIONS <= $partitions) {
   $partitions = $limit - $MIN_FILES_WITHOUT_PARTITIONS;
   if ($threads > $partitions) { $threads = $partitions - 1; }
   print STDERR "Warning: file handle limit of $limit prevents using requested partitions. Reset partitions to $partitions. If you want more partitions, reset the limit and try again.\n";
}
if ($partitions <= $threads) {
   $partitions = $threads + 1;
   print STDERR "Warning: number of partitions should be > # threads. Adjusted partitions to be $partitions.\n";
}

print STDOUT "Running with $threads threads and $partitions partitions\n";
my $CA = getBinDirectory();
my $AMOS = "$CA/../../../AMOS/bin/";
my $wrk = makeAbsolute("");
my $asm = "asm";
my $caSGE  = `cat $specFile | awk '{if (match(\$1, \"sge\")== 1 && length(\$1) == 3 && match(\$1, \"#\") == 0) print \$0}'`;
chomp($caSGE);
if (length($caSGE) != 0) {
   if (!defined($sge) || length($sge) == 0) {
      $sge = $caSGE;
      $sge =~ s/sge\s*=\s*//;
   }

   $caSGE = "\"" .$caSGE . " -sync y\" sgePropagateHold=corAsm";
} else {
   $caSGE = "sge=\"" . " -sync y\" sgePropagateHold=corAsm";
}
my $scriptParams = `cat $specFile |awk -F '=' '{if (match(\$1, \"sgeScript\") == 1 && match(\$1, \"#\") == 0) print \$NF}'`;
chomp($scriptParams);
if (length($scriptParams) != 0) {
   if (!defined($sgeCorrection) || length($sgeCorrection) == 0) {
      $sgeCorrection = $scriptParams;
   }
}

my $useGrid = `cat $specFile | awk -F '=' '{if (match(\$1, \"useGrid\") == 1 && match(\$1, \"#\") == 0) print \$NF}'`;
chomp($useGrid);
if (length($useGrid) != 0) {
   $submitToGrid = $useGrid;
}
elsif (defined($sge)) {
   $submitToGrid = 1;
}

my $caCNS  = `cat $specFile | awk -F '=' '{if (match(\$1, \"cnsConcurrency\")== 1) print \$2}'`;
chomp($caCNS);
if (length($caCNS) != 0) {
   $consensusConcurrency = $caCNS;
}

if (! -e "$AMOS/bank-transact") {
   # try to use path
   my $amosPath = `which bank-transact`;
   chomp $amosPath;
   my @t = split '/', "$amosPath";
   pop @t;                      #  bank-transact 
   $AMOS = join '/', @t;  #  path to the assembler

   # if we really can't find it just give up
   if (! -e "$AMOS/bank-transact") {
      die "AMOS binaries: bank-transact not found in $AMOS\n";
   }
}
print STDERR "Starting correction...\n CA: $CA\nAMOS:$AMOS\n";

my $cmd = "";
runCommand("$wrk", "$CA/fastqToCA -libraryname PacBio -type sanger -innie -technology pacbio -reads " . makeAbsolute($fastqFile) . " > $wrk/$libraryname.frg"); 
runCommand($wrk, "$CA/runCA -s $specFile -p $asm -d temp$libraryname $caSGE stopAfter=initialStoreBuilding @fragFiles $wrk/$libraryname.frg");

# make assumption that we correct using all libraries preceeding pacbio
# figure out what number of libs we have and what lib is pacbio
my $numLib = `$CA/gatekeeper -dumpinfo temp$libraryname/$asm.gkpStore | grep LIB |awk '{print \$1}'`;
chomp($numLib);

my $minCorrectLib = 0;
my $maxCorrectLib = 0;
my $libToCorrect = 0;
for (my $i = 1; $i <= $numLib; $i++) {
   if (system("$CA/gatekeeper -isfeatureset $i doConsensusCorrection temp$libraryname/$asm.gkpStore") == 0) {
      $libToCorrect = $i;
    } else {
      if ($minCorrectLib == 0) { $minCorrectLib = $i; }
      $maxCorrectLib = $i;
   }
}

# now run the correction
$cmd  = "$CA/runCA ";
$cmd .=    "-s $specFile ";
$cmd .=    "-p $asm -d temp$libraryname ";
#$cmd .=    "doOverlapBasedTrimming=0 ";
$cmd .=    "ovlHashLibrary=$libToCorrect ";
$cmd .=    "ovlRefLibrary=$minCorrectLib-$maxCorrectLib ";
$cmd .=    "obtHashLibrary=$minCorrectLib-$maxCorrectLib ";
$cmd .=    "obtRefLibrary=$minCorrectLib-$maxCorrectLib ";
$cmd .=   "$caSGE stopAfter=overlapper";
runCommand($wrk, $cmd);

if (! -e "$wrk/temp$libraryname/$asm.layout.success") {
   open F, "> $wrk/temp$libraryname/runCorrection.sh" or die ("can't open '$wrk/temp$libraryname/runCorrection.sh'");
   print F "#!" . "/bin/sh\n";
   print F "\n";
   print F " if test -e $wrk/temp$libraryname/$asm.layout.success; then\n";
   print F "    echo Job previously completed successfully.\n";
   print F " else\n";
   print F "   $CA/correctPacBio \\\n";
   print F "      -t $threads \\\n";
   print F "       -p $partitions \\\n";
   print F "       -o $asm \\\n";
   print F "       -l $length \\\n";
   print F "        $repeats \\\n";
   print F "        -O $wrk/temp$libraryname/$asm.ovlStore \\\n";
   print F "        -G $wrk/temp$libraryname/$asm.gkpStore \\\n";
   print F "        -e 0.25 -c 0.25  -E 6.5 > $wrk/temp$libraryname/$asm.layout.err 2> $wrk/temp$libraryname/$asm.layout.err && touch $wrk/temp$libraryname/$asm.layout.success\n";
   print F " fi\n";
   close(F);
   chmod 0755, "$wrk/temp$libraryname/runCorrection.sh";

   if ($submitToGrid == 1) {
      runCommand("$wrk/temp$libraryname", "qsub $sge $sgeCorrection -sync y -cwd -N correct_$asm -j y -o /dev/null $wrk/temp$libraryname/runCorrection.sh");
   } else {
      runCommand("$wrk/temp$libraryname", "$wrk/temp$libraryname/runCorrection.sh");
   }
}

if (! -e "$wrk/temp$libraryname/runPartition.sh") {
   open F, "> $wrk/temp$libraryname/runPartition.sh" or die ("can't open '$wrk/temp$libraryname/runPartition.sh'");
   print F "#!" . "/bin/sh\n";
   print F "\n";
   print F "jobid=\$SGE_TASK_ID\n";
   print F "if test x\$jobid = x -o x\$jobid = xundefined; then\n";
   print F "jobid=\$1\n";
   print F "fi\n";
   print F "\n";
   print F "if test x\$jobid = x; then\n";
   print F "  echo Error: I need SGE_TASK_ID set, or a job index on the command line\n";
   print F "  exit 1\n";
   print F "fi\n";
   print F "\n";
   print F "if test -e $wrk/temp$libraryname/\$jobid.success ; then\n";
   print F "   echo Job previously completed successfully.\n";
   print F "else\n";
   print F "   numLays=`cat $wrk/temp$libraryname/$asm" . ".\$jobid.lay |grep \"{LAY\" |wc -l`\n";
   print F "   if test \$numLays = 0 ; then\n";
   print F "      touch $wrk/temp$libraryname/\$jobid.fasta\n";
   print F "      touch $wrk/temp$libraryname/\$jobid.qual\n";
   print F "      touch $wrk/temp$libraryname/\$jobid.success\n";
   print F "   else\n";
   print F "      $AMOS/bank-transact -b $wrk/temp$libraryname/$asm" . ".bnk_partition\$jobid.bnk -m $wrk/temp$libraryname/$asm.\$jobid" . ".lay -c > $wrk/temp$libraryname/bank-transact.\$jobid.err 2>&1\n";
   print F "      $AMOS/make-consensus -B -b $wrk/temp$libraryname/" . $asm . ".bnk_partition\$jobid.bnk > $wrk/temp$libraryname/\$jobid.out 2>&1 && touch $wrk/temp$libraryname/\$jobid.success\n";
   print F "      $AMOS/bank2fasta -e -q $wrk/temp$libraryname/\$jobid.qual -b $wrk/temp$libraryname/" . $asm . ".bnk_partition\$jobid.bnk > $wrk/temp$libraryname/\$jobid.fasta\n";
   print F "   fi\n";
   print F "fi\n";
   close(F);

   chmod 0755, "$wrk/temp$libraryname/runPartition.sh";

   if ($submitToGrid == 1) {
      runCommand("$wrk/temp$libraryname", "qsub $sge -sync y -cwd -N utg_$asm -t 1-$partitions -j y -o /dev/null $wrk/temp$libraryname/runPartition.sh");
   } else {
      for (my $i = 1; $i <=$partitions; $i++) {
         schedulerSubmit("$wrk/temp$libraryname/runPartition.sh $i");
      }
      schedulerSetNumberOfProcesses($consensusConcurrency);
      schedulerFinish();
   } 
}

for (my $i = 1; $i <=$partitions; $i++) {
  if (! -e "$wrk/temp$libraryname/$i.success") {
    die "Failed to run correction job $i. Remove $wrk/temp$libraryname/runPartition.sh to try again.\n";
  }
}

runCommand("$wrk/temp$libraryname", "cat `ls [1234567890]*.fasta |sort -rnk1` > corrected.fasta");
runCommand("$wrk/temp$libraryname", "cat `ls [1234567890]*.qual |sort -rnk1` > corrected.qual");
runCommand("$wrk", "$CA/convert-fasta-to-v2.pl -pacbio -s $wrk/temp$libraryname/corrected.fasta -q $wrk/temp$libraryname/corrected.qual -l $libraryname > $wrk/$libraryname.frg");
runCommand("$wrk/temp$libraryname", "cp corrected.fasta $wrk/$libraryname.fasta");
runCommand("$wrk/temp$libraryname", "cp corrected.qual  $wrk/$libraryname.qual");

# finally clean up the assembly directory
if ($cleanup == 1) {
   runCommand("$wrk", "rm -rf temp$libraryname");
}

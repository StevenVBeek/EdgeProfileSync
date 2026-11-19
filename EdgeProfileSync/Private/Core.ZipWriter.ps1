# Core helper: fast zip creation for many small files.
#
# Opening a file is expensive on machines with real-time antivirus (every open is scanned), and a zip
# archive can only be written by one thread. EdgeZipJob therefore reads the source files on several
# threads (into memory, bounded) while a single writer compresses them into the archive. The job runs in
# the background; PowerShell polls its counters to drive Write-Progress.

$script:EdgeZipWriterSource = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Threading;
using System.Threading.Tasks;

namespace EdgeProfileSync
{
    public sealed class ZipSkippedFile
    {
        public string Source { get; set; }
        public string Entry { get; set; }
        public string Reason { get; set; }
    }

    public sealed class EdgeZipJob
    {
        // Files up to this size are read on the reader threads; larger ones are streamed by the writer.
        private const long PrefetchLimit = 16L * 1024 * 1024;

        private long _bytesDone;
        private int _filesDone;
        private volatile string _current = string.Empty;
        private readonly ConcurrentQueue<ZipSkippedFile> _skipped = new ConcurrentQueue<ZipSkippedFile>();

        public long TotalBytes { get; private set; }
        public int TotalFiles { get; private set; }
        public long BytesDone { get { return Interlocked.Read(ref _bytesDone); } }
        public int FilesDone { get { return Volatile.Read(ref _filesDone); } }
        public string Current { get { return _current; } }
        public Task Task { get; private set; }
        public ZipSkippedFile[] Skipped { get { return _skipped.ToArray(); } }

        private sealed class Item
        {
            public int Index;
            public byte[] Data;      // null when streamed by the writer
            public string Error;
        }

        public static EdgeZipJob Start(string zipPath, string[] sources, string[] entries, long[] sizes, int readers)
        {
            if (sources.Length != entries.Length || sources.Length != sizes.Length)
                throw new ArgumentException("sources, entries and sizes must have the same length");
            var job = new EdgeZipJob();
            job.TotalFiles = sources.Length;
            long total = 0;
            foreach (var s in sizes) total += s;
            job.TotalBytes = total;
            job.Task = Task.Run(() => job.Run(zipPath, sources, entries, sizes, Math.Max(1, readers)));
            return job;
        }

        private static FileStream OpenShared(string path)
        {
            return new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete, 81920, FileOptions.SequentialScan);
        }

        private void Run(string zipPath, string[] sources, string[] entries, long[] sizes, int readers)
        {
            using (var queue = new BlockingCollection<Item>(boundedCapacity: 256))
            {
                var producer = Task.Run(() =>
                {
                    try
                    {
                        Parallel.For(0, sources.Length, new ParallelOptions { MaxDegreeOfParallelism = readers }, i =>
                        {
                            var item = new Item { Index = i };
                            if (sizes[i] <= PrefetchLimit)
                            {
                                try
                                {
                                    using (var fs = OpenShared(sources[i]))
                                    using (var ms = new MemoryStream((int)Math.Max(0, Math.Min(sizes[i], int.MaxValue))))
                                    {
                                        fs.CopyTo(ms);
                                        item.Data = ms.ToArray();
                                    }
                                }
                                catch (Exception ex) { item.Error = ex.Message; }
                            }
                            queue.Add(item);
                        });
                    }
                    finally { queue.CompleteAdding(); }
                });

                using (var stream = new FileStream(zipPath, FileMode.Create, FileAccess.ReadWrite, FileShare.None))
                using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, false))
                {
                    foreach (var item in queue.GetConsumingEnumerable())
                    {
                        int i = item.Index;
                        _current = entries[i];
                        if (item.Error != null)
                        {
                            _skipped.Enqueue(new ZipSkippedFile { Source = sources[i], Entry = entries[i], Reason = item.Error });
                        }
                        else
                        {
                            try
                            {
                                var entry = zip.CreateEntry(entries[i], CompressionLevel.Fastest);
                                try { entry.LastWriteTime = File.GetLastWriteTime(sources[i]); } catch { }
                                using (var output = entry.Open())
                                {
                                    if (item.Data != null) output.Write(item.Data, 0, item.Data.Length);
                                    else using (var fs = OpenShared(sources[i])) fs.CopyTo(output);
                                }
                            }
                            catch (IOException ex) when (item.Data == null)
                            {
                                // A large file vanished or got locked; the empty entry stays, report it.
                                _skipped.Enqueue(new ZipSkippedFile { Source = sources[i], Entry = entries[i], Reason = ex.Message });
                            }
                        }
                        Interlocked.Add(ref _bytesDone, sizes[i]);
                        Interlocked.Increment(ref _filesDone);
                    }
                }
                producer.GetAwaiter().GetResult();
            }
        }
    }
}
'@

function Initialize-EdgeZipWriter {
    # Compiles the zip writer once per session (about a second, on first use only).
    [CmdletBinding()]
    param()
    if ('EdgeProfileSync.EdgeZipJob' -as [type]) { return }
    Add-Type -TypeDefinition $script:EdgeZipWriterSource -Language CSharp -ErrorAction Stop
}

function Write-EdgeZipFromList {
    <#
    .SYNOPSIS
        Writes the given files into a new zip archive with parallel readers and a byte-based progress bar.
    .DESCRIPTION
        -Items: objects with Source (full path), Entry (path inside the zip, '/' separated) and Bytes.
        Files that cannot be read (vanished, locked) are skipped and returned as objects
        (Source, Entry, Reason); everything else ends up in the archive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][string]$ZipPath,
        [string]$Activity = 'Creating zip archive',
        [int]$ProgressId = 2,
        [int]$Readers = 8
    )
    Initialize-EdgeZipWriter
    $sources = [string[]]@($Items | ForEach-Object { $_.Source })
    $entries = [string[]]@($Items | ForEach-Object { $_.Entry })
    $sizes = [long[]]@($Items | ForEach-Object { [long]$_.Bytes })

    $job = [EdgeProfileSync.EdgeZipJob]::Start($ZipPath, $sources, $entries, $sizes, $Readers)
    $progress = New-EdgeProgress -Activity $Activity -Total $job.TotalBytes -Id $ProgressId
    try {
        while (-not $job.Task.Wait(250)) {
            Update-EdgeProgress -Progress $progress -Done $job.BytesDone `
                -Status ('File {0:N0} of {1:N0}' -f $job.FilesDone, $job.TotalFiles) -CurrentOperation $job.Current
        }
        # Surfaces an exception of the background job (disk full, destination not writable, ...).
        $job.Task.GetAwaiter().GetResult()
    }
    finally {
        Complete-EdgeProgress -Progress $progress
    }
    $job.Skipped
}

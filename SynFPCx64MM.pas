/// Fast Memory Manager for FPC x86_64
// - this unit is a part of the freeware Synopse mORMot framework
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit SynFPCx64MM;

{
  *****************************************************************************

    A Multi-thread Friendly Memory Manager for FPC written in x86_64 assembly
    - based on FastMM4 proven algorithms by Pierre le Riche
    - targetting Windows and Linux multi-threaded Services
    - only for FPC on the x86_64 target - use the original heap on Delphi or ARM
    - code has been reduced to the only necessary featureset for production
    - huge asm refactoring for cross-platform, compactness and efficiency
    - report detailed statistics (with threads contention and memory leaks)
    - mremap() makes large block ReallocMem a breeze on Linux :)
    - inlined SSE2 movaps loop is more efficient that subfunction(s)
    - round-robin of tiny blocks (<=128 bytes) for better thread scaling

    Usage: include this unit as the very first in your FPC project uses clause

    Why another Memory Manager on FPC?
    - The built-in heap.inc is well written and cross-platform and cross-CPU,
      but its threadvar arena for small blocks tends to consume a lot of memory
      on multi-threaded servers, and has suboptimal allocation performance
    - C memory managers (glibc, Intel TBB, jemalloc) have a very high RAM
      consumption (especially Intel TBB) and panic/SIGKILL on any GPF
    - Pascal alternatives (FastMM4,ScaleMM2,BrainMM) are Windows+Delphi specific
    - It was so fun deeping into SSE2 x86_64 assembly and Pierre's insight
    - Resulting code is still easy to understand and maintain

    IMPORTANT NOTICE: only tested on-site - feedback is (very) welcome!

  *****************************************************************************

    This file is part of Synopse framework.

    Synopse framework. Copyright (C) 2020 Arnaud Bouchez
      Synopse Informatique - https://synopse.info

  *** BEGIN LICENSE BLOCK *****
  Version: MPL 1.1/GPL 2.0/LGPL 2.1

  The contents of this file are subject to the Mozilla Public License Version
  1.1 (the "License"); you may not use this file except in compliance with
  the License. You may obtain a copy of the License at
  http://www.mozilla.org/MPL

  Software distributed under the License is distributed on an "AS IS" basis,
  WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
  for the specific language governing rights and limitations under the License.

  The Original Code is Synopse mORMot framework.

  The Initial Developer of the Original Code is Arnaud Bouchez.

  Portions created by the Initial Developer are Copyright (C) 2020
  the Initial Developer. All Rights Reserved.

  Contributor(s):

  Alternatively, the contents of this file may be used under the terms of
  either the GNU General Public License Version 2 or later (the "GPL"), or
  the GNU Lesser General Public License Version 2.1 or later (the "LGPL"),
  in which case the provisions of the GPL or the LGPL are applicable instead
  of those above. If you wish to allow use of your version of this file only
  under the terms of either the GPL or the LGPL, and not to allow others to
  use your version of this file under the terms of the MPL, indicate your
  decision by deleting the provisions above and replace them with the notice
  and other provisions required by the GPL or the LGPL. If you do not delete
  the provisions above, a recipient may use your version of this file under
  the terms of any one of the MPL, the GPL or the LGPL.

  ***** END LICENSE BLOCK *****

}

// if defined, includes more detailed information to WriteHeapStatus()
{.$define FPCMM_DEBUG}

// if defined, leaks will be checked and written to the console at shutdown
// - only basic information will be included: more debugging information may
// be gathered using heaptrc or valgrid
{.$define FPCMM_REPORTMEMORYLEAKS}

// if defined, won't check the IsMultiThread global but assume it is true
// - should be enabled e.g. for a multi-threaded Server Daemon instance
{.$define FPCMM_ASSUMEMULTITHREAD}

// could be defined on AMD CPU, or oldest Intel before SkylakeX
// - on SkylakeX (Intel 7th gen), "pause" opcode went from 10-20 to 140 cycles
{.$define FPCMM_PAUSEMORE}

// if defined, won't use mremap but a regular getmem/move/freemem pattern
// - depending on the actual system (e.g. on a VM), mremap may be slower
{.$define FPCMM_NOMREMAP}

// if defined, tiny blocks <= 128 bytes will have a bigger round-robin cycle
// - try to enable it if unexpected SmallGetmemSleepCount/SmallFreememSleepCount
// and SleepCount/SleepTime contentions are reported by CurrentHeapStatus
// - this will use 4x more arenas to share among the threads
// - warning: depending on the workload and hardware, it may actually be slower
{.$define FPCMM_BOOST}
{.$define FPCMM_BOOSTER}

// if defined, will export libc-like functions, and not replace the FPC MM
// - e.g. to use this unit as a stand-alone C memory allocator
{.$define FPCMM_STANDALONE}


interface

{$ifdef FPC}
  // cut-down version of Synopse.inc to make this unit standalone
  {$mode Delphi}
  {$asmmode Intel}
  {$inline on}
  {$R-} // disable Range checking in our code
  {$S-} // disable Stack checking in our code
  {$W-} // disable stack frame generation
  {$Q-} // disable overflow checking in our code
  {$B-} // expect short circuit boolean
  {$ifdef CPUX64}
    {$define FPC_CPUX64} // this unit is for FPC + x86_64 only
  {$endif CPUX64}
  {$ifdef FPCMM_BOOSTER}
    {$define FPCMM_BOOST}
  {$endif FPCMM_BOOSTER}
  {$ifdef FPCMM_BOOST}
    {$undef FPCMM_DEBUG} // when performance matters more than stats
    {$define FPCMM_ASSUMEMULTITHREAD}
  {$endif FPCMM_BOOST}
{$endif FPC}

{$ifdef FPC_CPUX64}

type
  /// Arena (middle/large) heap information as returned by CurrentHeapStatus
  TMMStatusArena = record
    /// how many bytes are currently reserved (mmap) to the Operating System
    CurrentBytes: PtrUInt;
    /// how many bytes have been reserved (mmap) to the Operating System
    CumulativeBytes: PtrUInt;
    {$ifdef FPCMM_DEBUG}
    /// maximum bytes count reserved (mmap) to the Operating System
    PeakBytes: PtrUInt;
    /// how many VirtualAlloc/mmap calls to the Operating System did occur
    CumulativeAlloc: PtrUInt;
    /// how many VirtualFree/munmap calls to the Operating System did occur
    CumulativeFree: PtrUInt;
    {$endif FPCMM_DEBUG}
    /// how many times this Arena did wait from been unlocked by another thread
    SleepCount: PtrUInt;
  end;

  /// heap information as returned by CurrentHeapStatus
  TMMStatus = record
    /// how many tiny/small memory blocks (<=2600) are currently allocated
    SmallBlocks: PtrUInt;
    /// how many bytes of tiny/small memory blocks are currently allocated
    // - this size is part of the Medium arena
    SmallBlocksSize: PtrUInt;
    /// contain blocks up to 256KB (small and medium blocks)
    Medium: TMMStatusArena;
    /// large blocks > 256KB which are directly handled by the Operating System
    Large: TMMStatusArena;
    {$ifdef FPCMM_DEBUG}
    /// how much MicroSeconds was spend within Sleep/NanoSleep API calls
    // - under Windows, is not an exact, but only indicative value
    SleepTime: PtrUInt;
    {$endif FPCMM_DEBUG}
    /// how many times the Operating System Sleep/NanoSleep API was called
    // - in a perfect world, should be as small as possible
    SleepCount: PtrUInt;
    /// how many times Getmem() did block and wait for a small block
    // - see also GetSmallBlockContention()
    SmallGetmemSleepCount: PtrUInt;
    /// how many times Freemem() did block and wait for a small block
    // - see also GetSmallBlockContention()
    SmallFreememSleepCount: PtrUInt;
  end;
  PMMStatus = ^TMMStatus;


{$ifdef FPCMM_STANDALONE}

/// should be called before using any memory function
procedure InitializeMemoryManager;

/// allocate a new memory buffer
function _GetMem(size: PtrInt): pointer;

/// allocate a new zeroed memory buffer
function _AllocMem(Size: PtrInt): pointer;

/// release a memory buffer
function _FreeMem(P: pointer): PtrInt;

/// change the size of a memory buffer
function _ReallocMem(var P: pointer; Size: PtrInt): pointer;

/// retrieve the maximum size (i.e. the allocated size) of a memory buffer
function _MemSize(P: pointer): PtrUInt;

/// retrieve high-level statistics about the current memory manager state
function CurrentHeapStatus: TMMStatus;

/// should be called to finalize this memory manager process and release all RAM
procedure FreeAllMemory;

{$undef FPCMM_DEBUG} // excluded FPC-specific debugging

/// IsMultiThread global variable is not correct outside of the FPC RTL
{$define FPCMM_ASSUMEMULTITHREAD}
/// not supported to reduce dependencies
{$undef FPCMM_REPORTMEMORYLEAKS}

{$else}

  /// one GetSmallBlockContention info about unexpected multi-thread waiting
  // - a single GetmemBlockSize or FreememBlockSize non 0 field is set
  TSmallBlockContention = packed record
    /// how many times a small block getmem/freemem has been waiting for unlock
    SleepCount: cardinal;
    /// the small block size on which Getmem() has been blocked - or 0
    GetmemBlockSize: cardinal;
    /// the small block size on which Freemem() has been blocked - or 0
    FreememBlockSize: cardinal;
  end;

  /// small blocks detailed information as returned GetSmallBlockContention
  TSmallBlockContentionDynArray = array of TSmallBlockContention;

  /// one GetSmallBlockStatus information
  TSmallBlockStatus = packed record
    /// how many times a memory block of this size has been allocated
    Total: cardinal;
    /// how many memory blocks of this size are currently allocated
    Current: cardinal;
    /// the standard size of the small memory block
    BlockSize: cardinal;
  end;

  /// small blocks detailed information as returned GetSmallBlockStatus
  TSmallBlockStatusDynArray = array of TSmallBlockStatus;


/// retrieve high-level statistics about the current memory manager state
// - see also GetSmallBlockContention for detailed small blocks information
function CurrentHeapStatus: TMMStatus;


type
  TSmallBlockOrderBy = (obTotal, obCurrent, obBlockSize);

/// retrieve the use counts of allocated small blocks
// - returns maxcount biggest results, sorted by "orderby" field occurence
function GetSmallBlockStatus(maxcount: integer = 10;
  orderby: TSmallBlockOrderBy = obTotal): TSmallBlockStatusDynArray;

/// retrieve all small blocks which suffered from blocking during multi-thread
// - returns maxcount biggest results, sorted by SleepCount occurence
function GetSmallBlockContention(maxcount: integer = 10): TSmallBlockContentionDynArray;


/// convenient debugging function into the console
// - if smallblockcontentioncount > 0, includes GetSmallBlockContention() info
// up to the smallblockcontentioncount biggest occurences
procedure WriteHeapStatus(const context: shortstring = '';
  smallblockstatuscount: integer = 9; smallblockcontentioncount: integer = 9);

{$endif FPCMM_STANDALONE}

{$endif FPC_CPUX64}



implementation

{
   High-level Algorithms Description
  -----------------------------------

  The allocator handles the following families of memory blocks:
  - TINY   <= 128 B (or <= 256 B for FPCMM_BOOST) - not existing in FastMM4
    Round-robin distribution into several arenas, fed from medium blocks
    (fair scaling from multi-threaded calls, with no threadvar nor GC involved)
  - SMALL  <= 2600 B
    Single arena per block size, fed from medium blocks
  - MEDIUM <= 256 KB
    Pool of bitmap-marked chunks, fed from 1MB of OS mmap/virtualalloc
  - LARGE  > 256 KB
    Directly fed from OS mmap/virtualalloc with mremap when growing

  About locking:
  - Tiny and Small blocks have their own per-size lock, in every arena
  - Medium and Large blocks have one giant lock each
  - ThreadSwitch/FpNanoSleep OS call is done after initial spinning
  - FPCMM_DEBUG / WriteHeapStatus allows to identify the lock contention

}

{$ifdef FPC_CPUX64}
// this unit is available only for FPC + X86_64 CPU


{ ********* Operating System Specific API Calls }

{$ifdef MSWINDOWS}

var
  HeapStatus: TMMStatus;

const
  kernel32 = 'kernel32.dll';

  MEM_COMMIT = $1000;
  MEM_RESERVE  = $2000;
  MEM_RELEASE = $8000;
  MEM_FREE = $10000;
  MEM_TOP_DOWN = $100000;

  PAGE_READWRITE = 4;

function VirtualAlloc(lpAddress: pointer;
   dwSize: PtrUInt; flAllocationType, flProtect: Cardinal): pointer; stdcall;
  external kernel32 name 'VirtualAlloc';
function VirtualFree(lpAddress: pointer; dwSize: PtrUInt;
   dwFreeType: Cardinal): LongBool; stdcall;
  external kernel32 name 'VirtualFree';
procedure SwitchToThread; stdcall;
  external kernel32 name 'SwitchToThread';
procedure SleepMS(dwMilliseconds: Cardinal); stdcall;
  external kernel32 name 'Sleep';

procedure ReleaseCore;
begin
  SwitchToThread;
  inc(HeapStatus.SleepCount);
  {$ifdef FPCMM_DEBUG}
  inc(HeapStatus.SleepTime, 100); // wild guess to have some debug info
  {$endif FPCMM_DEBUG}
end;

function AllocMedium(Size: PtrInt): pointer; inline;
begin
  result := VirtualAlloc(nil, Size, MEM_COMMIT, PAGE_READWRITE);
end;

function AllocLarge(Size: PtrInt): pointer; inline;
begin
  result := VirtualAlloc(nil, Size, MEM_COMMIT or MEM_TOP_DOWN, PAGE_READWRITE);
end;

procedure Free(ptr: pointer; Size: PtrInt); inline;
begin
  VirtualFree(ptr, 0, MEM_RELEASE);
end;

{$define FPCMM_NOMREMAP}

{$else}

uses
  {$ifndef DARWIN}
  syscall,
  {$endif DARWIN}
  BaseUnix;

var
  HeapStatus: TMMStatus;

// we directly call the Kernel, so this unit doesn't require any libc

function AllocMedium(Size: PtrInt): pointer; inline;
begin
  result := fpmmap(nil, Size, PROT_READ or PROT_WRITE,
    MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
end;

function AllocLarge(Size: PtrInt): pointer; inline;
begin
  result := fpmmap(nil, Size, PROT_READ or PROT_WRITE,
    MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
end;

procedure Free(ptr: pointer; Size: PtrInt); inline;
begin
  Size := fpmunmap(ptr, Size);
  // assert(Size = 0);
end;

{$ifdef LINUX}

const
  CLOCK_MONOTONIC = 1;

{$ifndef FPCMM_NOMREMAP}

const
  syscall_nr_mremap = 25;
  MREMAP_MAYMOVE = 1;

function fpmremap(addr: pointer; old_len, new_len: size_t; may_move: longint): pointer; inline;
begin
  result := pointer(do_syscall(syscall_nr_mremap, TSysParam(addr),
    TSysParam(old_len), TSysParam(new_len), TSysParam(may_move)));
end;

{$endif FPCMM_NOMREMAP}

{$else}

const
  {$ifdef OPENBSD}
  CLOCK_MONOTONIC = 3;
  {$else}
  CLOCK_MONOTONIC = 4;
  {$endif OPENBSD}

{$define FPCMM_NOMREMAP}

{$endif LINUX}

procedure NSleep(nsec: PtrInt); inline;
var
  t: Ttimespec;
begin
  // note: nanosleep() adds a few dozen of microsecs for context switching
  t.tv_sec := 0;
  t.tv_nsec := nsec;
  fpnanosleep(@t, nil);
end;

{$ifdef DARWIN}

function QueryPerformanceMicroSeconds: Int64; inline;
begin
  result := 0;
end;

{$else}

function clock_gettime(clk_id: integer; tp: ptimespec): integer; inline;
begin
  // calling the libc may be slightly faster thanks to vDSO but not here
  result := do_SysCall(syscall_nr_clock_gettime, tsysparam(clk_id), tsysparam(tp));
end;

function QueryPerformanceMicroSeconds: PtrUInt; inline;
var
  r : TTimeSpec;
begin
  if clock_gettime(CLOCK_MONOTONIC, @r) = 0 then
    result := PtrUInt(r.tv_nsec) div 1000 + PtrUInt(r.tv_sec) * 1000000
  else
    result := 0;
end;

{$endif DARWIN}

const
  // empirically identified as a convenient value with a recent Linux Kernel
  NANOSLEEP = 10;

{$ifdef FPCMM_DEBUG}

procedure SleepSetTime(start: QWord); nostackframe; assembler;
asm
  push start
  call QueryPerformanceMicroSeconds
  pop rcx
  lea rdx, [rip + HeapStatus]
  sub rax, rcx
lock xadd qword ptr[rdx + TMMStatus.SleepTime], rax
lock inc qword ptr[rdx + TMMStatus.SleepCount]
end;

procedure ReleaseCore;
var
  start: QWord;
begin
  start := QueryPerformanceMicroSeconds; // is part of the wait
  NSleep(NANOSLEEP); // similar to ThreadSwitch()
  SleepSetTime(start);
end;

{$else}

procedure ReleaseCore;
begin
  NSleep(NANOSLEEP); // similar to ThreadSwitch()
  inc(HeapStatus.SleepCount); // indicative counter
end;

{$endif FPCMM_DEBUG}

{$endif MSWINDOWS}


{ ********* Some Assembly Helpers }

procedure NotifyAlloc(var Arena: TMMStatusArena; Size: PtrUInt);
  nostackframe; assembler;
asm
     mov  rax, Size
lock xadd qword ptr[Arena].TMMStatusArena.CurrentBytes, rax
lock xadd qword ptr[Arena].TMMStatusArena.CumulativeBytes, Size
     {$ifdef FPCMM_DEBUG}
lock inc  qword ptr[Arena].TMMStatusArena.CumulativeAlloc
     mov  rax, qword ptr[Arena].TMMStatusArena.CurrentBytes
     cmp  rax, qword ptr[Arena].TMMStatusArena.PeakBytes
     jbe  @s
     mov  qword ptr[Arena].TMMStatusArena.PeakBytes, rax
@s:  {$endif FPCMM_DEBUG}
end;

procedure NotifyFree(var Arena: TMMStatusArena; Size: PtrUInt);
  nostackframe; assembler;
asm
     neg Size
lock xadd qword ptr[Arena].TMMStatusArena.CurrentBytes, Size
     {$ifdef FPCMM_DEBUG}
lock inc  qword ptr[Arena].TMMStatusArena.CumulativeFree
     {$endif FPCMM_DEBUG}
end;

// called from ReallocateLargeBlock with regular parameters
procedure MoveLarge(src, dst: pointer; cnt: PtrInt); nostackframe; assembler;
asm
      sub cnt, 8
      add src, cnt
      add dst, cnt
      neg cnt
      jns @z
      align 16
@s:   movaps xmm0, oword ptr [src + cnt]
      movntdq oword ptr [dst + cnt], xmm0 // non-temporal loop
      add cnt, 16
      js @s
      sfence
@z:   mov rax, qword ptr [src + cnt]
      mov qword ptr [dst + cnt], rax
end;



{ ********* Constants and Data Structures Definitions }

const
  NumSmallBlockTypes = 46;
  MaximumSmallBlockSize = 2608;
  SmallBlockSizes: array[0..NumSmallBlockTypes - 1] of word = (
   16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 256,
   272, 288, 304, 320, 352, 384, 416, 448, 480, 528, 576, 624, 672, 736, 800,
   880, 960, 1056, 1152, 1264, 1376, 1504, 1648, 1808, 1984, 2176, 2384,
   MaximumSmallBlockSize, MaximumSmallBlockSize, MaximumSmallBlockSize);
  {$ifdef FPCMM_BOOST} // try if the more arenas, the better multi-threadable
  {$ifdef FPCMM_BOOSTER}
  NumTinyBlockTypesPO2 = 4;
  NumTinyBlockArenasPO2 = 5; // will probably end up with Medium lock contention
  {$else}
  NumTinyBlockTypesPO2 = 4;  // tiny are <= 256 bytes
  NumTinyBlockArenasPO2 = 4; // 16 + 1 arenas
  {$endif FPCMM_BOOSTER}
  {$else}
  NumTinyBlockTypesPO2 = 3;  // multiple arenas for tiny blocks <= 128 bytes
  NumTinyBlockArenasPO2 = 3; // 8 round-robin arenas + 1 main by default
  {$endif FPCMM_BOOST}
  NumTinyBlockTypes = 1 shl NumTinyBlockTypesPO2;
  NumTinyBlockArenas = 1 shl NumTinyBlockArenasPO2;
  NumSmallInfoBlock = NumSmallBlockTypes + NumTinyBlockArenas * NumTinyBlockTypes;
  SmallBlockGranularity = 16;
  TargetSmallBlocksPerPool = 48;
  MinimumSmallBlocksPerPool = 12;

  MediumBlockPoolSizeMem = 20 * 64 * 1024;
  MediumBlockPoolSize = MediumBlockPoolSizeMem - 16;
  MediumBlockSizeOffset = 48;
  MinimumMediumBlockSize = 11 * 256 + MediumBlockSizeOffset;
  MediumBlockBinsPerGroup = 32;
  MediumBlockBinGroupCount = 32;
  MediumBlockBinCount = MediumBlockBinGroupCount * MediumBlockBinsPerGroup;
  MediumBlockGranularity = 256;
  MaximumMediumBlockSize =
    MinimumMediumBlockSize + (MediumBlockBinCount - 1) * MediumBlockGranularity;
  OptimalSmallBlockPoolSizeLowerLimit =
    29 * 1024 - MediumBlockGranularity + MediumBlockSizeOffset;
  OptimalSmallBlockPoolSizeUpperLimit =
    64 * 1024 - MediumBlockGranularity + MediumBlockSizeOffset;
  MaximumSmallBlockPoolSize =
    OptimalSmallBlockPoolSizeUpperLimit + MinimumMediumBlockSize;
  LargeBlockGranularity = 65536;

  IsFreeBlockFlag = 1;
  IsMediumBlockFlag = 2;
  IsSmallBlockPoolInUseFlag = 4;
  IsLargeBlockFlag = 4;
  PreviousMediumBlockIsFreeFlag = 8;
  LargeBlockIsSegmented = 8;
  DropSmallFlagsMask = -8;
  ExtractSmallFlagsMask = 7;
  DropMediumAndLargeFlagsMask = -16;
  ExtractMediumAndLargeFlagsMask = 15;

  // we use pause before ReleaseCore API call when spinning locks
  {$ifdef FPCMM_PAUSEMORE}
  // pause opcode latency is around 10 cycles on AMD or oldest Intel CPU
  SpinFactor = 10;
  {$else}
  // pause is 140 cycles since SkylakeX - see http://tiny.cc/010ioz
  SpinFactor = 1;
  {$endif FPCMM_PAUSEMORE}
  SpinSmallGetmemLockCount = 10 * SpinFactor;
  SpinSmallFreememLockCount = 2 * SpinFactor; // _freemem has lots of collision
  SpinMediumLockCount = 500 * SpinFactor;
  SpinLargeLockCount = 500 * SpinFactor;

  SmallBlockDownsizeCheckAdder = 64;
  SmallBlockUpsizeAdder = 32;
  MediumInPlaceDownsizeLimit = MinimumMediumBlockSize div 4;

type
  PSmallBlockPoolHeader = ^TSmallBlockPoolHeader;

  // information for each small block size - 64 bytes long = CPU cache line
  TSmallBlockType = record
    BlockTypeLocked: boolean;
    AllowedGroupsForBlockPoolBitmap: Byte;
    BlockSize: Word;
    MinimumBlockPoolSize: Word;
    OptimalBlockPoolSize: Word;
    NextPartiallyFreePool: PSmallBlockPoolHeader;
    PreviousPartiallyFreePool: PSmallBlockPoolHeader;
    NextSequentialFeedBlockAddress: pointer;
    MaxSequentialFeedBlockAddress: pointer;
    CurrentSequentialFeedPool: PSmallBlockPoolHeader;
    GetmemCount: cardinal;
    FreememCount: cardinal;
    GetmemSleepCount: cardinal;
    FreememSleepCount: cardinal;
  end;
  PSmallBlockType = ^TSmallBlockType;

  TSmallBlockTypes = array[0..NumSmallBlockTypes - 1] of TSmallBlockType;
  TTinyBlockTypes = array[0..NumTinyBlockTypes - 1] of TSmallBlockType;

  TSmallBlockInfo = record
    Small: TSmallBlockTypes;
    Tiny: array[0..NumTinyBlockArenas - 1] of TTinyBlockTypes;
    GetmemLookup: array[0..
      (MaximumSmallBlockSize - 1) div SmallBlockGranularity] of byte;
    {$ifndef FPCMM_ASSUMEMULTITHREAD}
    IsMultiThreadPtr: PBoolean; // safe access to IsMultiThread global variable
    {$endif FPCMM_ASSUMEMULTITHREAD}
    TinyCurrentArena: integer;
  end;

  TSmallBlockPoolHeader = record
    BlockType: PSmallBlockType;
    {$ifdef CPU32}
    Padding32Bits: cardinal;
    {$endif}
    NextPartiallyFreePool: PSmallBlockPoolHeader;
    PreviousPartiallyFreePool: PSmallBlockPoolHeader;
    FirstFreeBlock: pointer;
    BlocksInUse: Cardinal;
    SmallBlockPoolSignature: Cardinal;
    FirstBlockPoolPointerAndFlags: PtrUInt;
  end;

  PMediumBlockPoolHeader = ^TMediumBlockPoolHeader;
  TMediumBlockPoolHeader = record
    PreviousMediumBlockPoolHeader: PMediumBlockPoolHeader;
    NextMediumBlockPoolHeader: PMediumBlockPoolHeader;
    Reserved1: PtrUInt;
    FirstMediumBlockSizeAndFlags: PtrUInt;
  end;

  PMediumFreeBlock = ^TMediumFreeBlock;
  TMediumFreeBlock = record
    PreviousFreeBlock: PMediumFreeBlock;
    NextFreeBlock: PMediumFreeBlock;
  end;

  TMediumBlockInfo = record
    Locked: boolean;
    PoolsCircularList: TMediumBlockPoolHeader;
    LastSequentiallyFed: pointer;
    SequentialFeedBytesLeft: Cardinal;
    BinGroupBitmap: Cardinal;
    BinBitmaps: array[0..MediumBlockBinGroupCount - 1] of Cardinal;
    Bins: array[0..MediumBlockBinCount - 1] of TMediumFreeBlock;
  end;

  PLargeBlockHeader = ^TLargeBlockHeader;
  TLargeBlockHeader = record
    PreviousLargeBlockHeader: PLargeBlockHeader;
    NextLargeBlockHeader: PLargeBlockHeader;
    UserAllocatedSize: PtrUInt;
    BlockSizeAndFlags: PtrUInt;
  end;

const
  BlockHeaderSize = SizeOf(pointer);
  SmallBlockPoolHeaderSize = SizeOf(TSmallBlockPoolHeader);
  MediumBlockPoolHeaderSize = SizeOf(TMediumBlockPoolHeader);
  LargeBlockHeaderSize = SizeOf(TLargeBlockHeader);

var
  SmallBlockInfo: TSmallBlockInfo;
  MediumBlockInfo: TMediumBlockInfo;

  LargeBlocksLocked: boolean;
  LargeBlocksCircularList: TLargeBlockHeader;


{ ********* Shared Routines }

procedure LockMediumBlocks; nostackframe; assembler;
asm
     // on input: rcx=MediumBlockInfo.Locked on output: r10=MediumBlockInfo
@s:  mov  edx, SpinMediumLockCount
     mov  r8d, $100
@sp: pause
     mov  eax, r8d
     dec  edx
     jz   @rc
     cmp  byte ptr[rcx], ah // don't flush the CPU cache if Locked still true
     je   @sp
lock cmpxchg byte ptr [rcx], ah
     je   @ok
     jmp  @sp
@rc: push rsi // preserve POSIX ABI registers
     push rdi
     call ReleaseCore
     pop  rdi
     pop  rsi
     lea  r10, [rip + MediumBlockInfo]
     lea  rax, [rip + HeapStatus] // simple inc within lock
     inc  qword ptr [rax].TMMStatus.Medium.SleepCount
     lea  rcx, [r10].TMediumBlockInfo.Locked
     jmp @s
@ok:
end;

procedure InsertMediumBlockIntoBin; nostackframe; assembler;
asm
  // rcx=MediumFreeBlock edx=MediumBlockSize r10=MediumBlockInfo - even on POSIX
  mov rax, rcx
  // Get the bin number for this block size
  sub edx, MinimumMediumBlockSize
  shr edx, 8
  // Validate the bin number
  sub edx, MediumBlockBinCount - 1
  sbb ecx, ecx
  and edx, ecx
  add edx, MediumBlockBinCount - 1
  mov r9, rdx
  // Get the bin address in rcx
  shl edx, 4
  lea rcx, [r10 + rdx + TMediumBlockInfo.Bins]
  // Bins are LIFO, se we insert this block as the first free block in the bin
  mov rdx, TMediumFreeBlock[rcx].NextFreeBlock
  mov TMediumFreeBlock[rax].PreviousFreeBlock, rcx
  mov TMediumFreeBlock[rax].NextFreeBlock, rdx
  mov TMediumFreeBlock[rdx].PreviousFreeBlock, rax
  mov TMediumFreeBlock[rcx].NextFreeBlock, rax
  // Was this bin empty?
  cmp rdx, rcx
  jne @Done
  // Get the bin number in ecx
  mov rcx, r9
  // Get the group number in edx
  mov rdx, r9
  shr edx, 5
  // Flag this bin as not empty
  mov eax, 1
  shl eax, cl
  lea r8, [r10 + TMediumBlockInfo.BinBitmaps]
  or dword ptr [r8 + rdx * 4], eax
  // Flag the group as not empty
  mov eax, 1
  mov ecx, edx
  shl eax, cl
  or [r10 + TMediumBlockInfo.BinGroupBitmap], eax
@Done:
end;

procedure RemoveMediumFreeBlock; nostackframe; assembler;
asm
  // rcx=MediumFreeBlock r10=MediumBlockInfo - even on POSIX
  // Get the current previous and next blocks
  mov rdx, TMediumFreeBlock[rcx].PreviousFreeBlock
  mov rcx, TMediumFreeBlock[rcx].NextFreeBlock
  // Remove this block from the linked list
  mov TMediumFreeBlock[rcx].PreviousFreeBlock, rdx
  mov TMediumFreeBlock[rdx].NextFreeBlock, rcx
  // Is this bin now empty? If the previous and next free block pointers are
  // equal, they must point to the bin
  cmp rcx, rdx
  jne @Done
  // Get the bin number for this block size in rcx
  lea r8, [r10 + TMediumBlockInfo.Bins]
  sub rcx, r8
  mov edx, ecx
  shr ecx, 4
  // Get the group number in edx
  shr edx, 9
  // Flag this bin as empty
  mov eax, -2
  rol eax, cl
  lea r8, [r10 + TMediumBlockInfo.BinBitmaps]
  and dword ptr [r8 + rdx * 4], eax
  jnz @Done
  // Flag this group as empty
  mov eax, -2
  mov ecx, edx
  rol eax, cl
  and [r10 + TMediumBlockInfo.BinGroupBitmap], eax
@Done:
end;

procedure BinMediumSequentialFeedRemainder; nostackframe; assembler;
asm
  // r10=MediumBlockInfo - even on POSIX
  mov eax, [r10 + TMediumBlockInfo.SequentialFeedBytesLeft]
  test eax, eax
  jz @Done
  // Get a pointer to the last sequentially allocated medium block
  mov rax, [r10 + TMediumBlockInfo.LastSequentiallyFed]
  // Is the block that was last fed sequentially free?
  test byte ptr [rax - BlockHeaderSize], IsFreeBlockFlag
  jnz @LastBlockFedIsFree
  // Set the "previous block is free" flag in the last block fed
  or qword ptr [rax - BlockHeaderSize], PreviousMediumBlockIsFreeFlag
  // Get the remainder in edx
  mov edx, [r10 + TMediumBlockInfo.SequentialFeedBytesLeft]
  // Point eax to the start of the remainder
  sub rax, rdx
@BinTheRemainder:
  // rax = start of remainder, edx = size of remainder
  // Store the size of the block as well as the flags
  lea rcx, [rdx + IsMediumBlockFlag + IsFreeBlockFlag]
  mov [rax - BlockHeaderSize], rcx
  // Store the trailing size marker
  mov [rax + rdx - 16], rdx
  // Bin this medium block
  cmp edx, MinimumMediumBlockSize
  jb @Done
  mov rcx, rax
  call InsertMediumBlockIntoBin // rcx=APMediumFreeBlock, edx=AMediumBlockSize
  ret
@LastBlockFedIsFree:
  // Drop the flags
  mov rdx, DropMediumAndLargeFlagsMask
  and rdx, [rax - BlockHeaderSize]
  // Free the last block fed
  cmp edx, MinimumMediumBlockSize
  jb @DontRemoveLastFed
  // Last fed block is free - remove it from its size bin
  mov rcx, rax
  call RemoveMediumFreeBlock // rcx = APMediumFreeBlock
  // Re-read rax and rdx
  mov rax, [r10 + TMediumBlockInfo.LastSequentiallyFed]
  mov rdx, DropMediumAndLargeFlagsMask
  and rdx, [rax - BlockHeaderSize]
@DontRemoveLastFed:
  // Get the number of bytes left in ecx
  mov ecx, [r10 + TMediumBlockInfo.SequentialFeedBytesLeft]
  // rax = remainder start, rdx = remainder size
  sub rax, rcx
  add edx, ecx
  jmp @BinTheRemainder
@Done:
end;

procedure FreeMedium(ptr: PMediumBlockPoolHeader);
begin
  Free(ptr, MediumBlockPoolSizeMem);
  NotifyFree(HeapStatus.Medium, MediumBlockPoolSizeMem);
end;

function AllocNewSequentialFeedMediumPool(blocksize: Cardinal): pointer;
var
  old: PMediumBlockPoolHeader;
  new: pointer;
begin
  BinMediumSequentialFeedRemainder;
  new := AllocMedium(MediumBlockPoolSizeMem);
  with MediumblockInfo do
  if new <> nil then
  begin
    old := PoolsCircularList.NextMediumBlockPoolHeader;
    PMediumBlockPoolHeader(new).PreviousMediumBlockPoolHeader := @PoolsCircularList;
   PoolsCircularList.NextMediumBlockPoolHeader := new;
    PMediumBlockPoolHeader(new).NextMediumBlockPoolHeader := old;
    old.PreviousMediumBlockPoolHeader := new;
    PPtrUInt(PByte(new) + MediumBlockPoolSize - BlockHeaderSize)^ := IsMediumBlockFlag;
    SequentialFeedBytesLeft :=
      (MediumBlockPoolSize - MediumBlockPoolHeaderSize) - blocksize;
    result := pointer(PByte(new) + MediumBlockPoolSize - blocksize);
    LastSequentiallyFed := result;
    PPtrUInt(PByte(result) - BlockHeaderSize)^ := blocksize or IsMediumBlockFlag;
    NotifyAlloc(HeapStatus.Medium, MediumBlockPoolSizeMem);
  end
  else
  begin
    SequentialFeedBytesLeft := 0;
    result := nil;
  end;
end;

procedure LockLargeBlocks; nostackframe; assembler;
asm
@s:  mov  eax, $100
     lea  rcx, [rip + LargeBlocksLocked]
lock cmpxchg byte ptr [rcx], ah
     je   @ok
     mov  edx, SpinLargeLockCount
@sp: pause
     mov  eax, $100
     dec  edx
     jz   @rc
     cmp  byte ptr [rcx], ah // don't flush the CPU cache if Locked still true
     je   @sp
lock cmpxchg byte ptr [rcx], ah
     je   @ok
     jmp  @sp
@rc: call ReleaseCore
     lea  rax, [rip + HeapStatus] // simple inc within lock
     inc  qword ptr [rax].TMMStatus.Large.SleepCount
     jmp @s
@ok:
end;

function AllocateLargeBlockFrom(size: PtrUInt;
   existing: pointer; oldsize: PtrUInt): pointer;
var
  blocksize: PtrUInt;
  header, old: PLargeBlockHeader;
begin
  blocksize := (size + LargeBlockHeaderSize +
    LargeBlockGranularity - 1 + BlockHeaderSize) and -LargeBlockGranularity;
  if existing = nil then
    header := AllocLarge(blocksize)
  else
    {$ifdef FPCMM_NOMREMAP}
    header := nil; // paranoid
    {$else}
    header := fpmremap(existing, oldsize, blocksize, MREMAP_MAYMOVE);
    {$endif FPCMM_NOMREMAP}
  if header <> nil then
  begin
    NotifyAlloc(HeapStatus.Large, blocksize);
    if existing <> nil then
      NotifyFree(HeapStatus.Large, oldsize);
    header.UserAllocatedSize := size;
    header.BlockSizeAndFlags := blocksize or IsLargeBlockFlag;
    LockLargeBlocks;
    old := LargeBlocksCircularList.NextLargeBlockHeader;
    header.PreviousLargeBlockHeader := @LargeBlocksCircularList;
    LargeBlocksCircularList.NextLargeBlockHeader := header;
    header.NextLargeBlockHeader := old;
    old.PreviousLargeBlockHeader := header;
    LargeBlocksLocked := False;
    inc(header);
  end;
  result := header;
end;

function AllocateLargeBlock(size: PtrUInt): pointer;
begin
  result := AllocateLargeBlockFrom(size, nil, 0);
end;

procedure FreeLarge(ptr: PLargeBlockHeader; size: PtrUInt);
begin
  NotifyFree(HeapStatus.Large, size);
  Free(ptr, size);
end;

function FreeLargeBlock(p: pointer): PtrInt;
var
  header, prev, next: PLargeBlockHeader;
begin
  header := pointer(PByte(p) - LargeBlockHeaderSize);
  LockLargeBlocks;
  prev := header.PreviousLargeBlockHeader;
  next := header.NextLargeBlockHeader;
  next.PreviousLargeBlockHeader := prev;
  prev.NextLargeBlockHeader := next;
  LargeBlocksLocked := False;
  FreeLarge(header, DropMediumAndLargeFlagsMask and header.BlockSizeAndFlags);
  result := 0; // assume success
end;

{$ifndef FPCMM_STANDALONE}

function _GetMem(size: PtrInt): pointer; forward;
function _FreeMem(P: pointer): PtrInt;   forward;

{$endif FPCMM_STANDALONE}

function ReallocateLargeBlock(p: pointer; size: PtrUInt): pointer;
var
  oldavail, minup, new: PtrUInt;
  {$ifndef FPCMM_NOMREMAP} prev, next, {$endif} header: PLargeBlockHeader;
begin
  header := pointer(PByte(p) - LargeBlockHeaderSize);
  oldavail := (DropMediumAndLargeFlagsMask and header^.BlockSizeAndFlags) -
    (LargeBlockHeaderSize + BlockHeaderSize);
  new := size;
  if size > oldavail then
  begin
    // size-up with 1/8 or 1/4 overhead for any future growing realloc
    if oldavail > 128 shl 20 then
      minup := oldavail + oldavail shr 3
    else
      minup := oldavail + oldavail shr 2;
    if size < minup then
      new := minup;
  end
  else
  if size >= (oldavail shr 1) then
  begin
    // small size-up within current buffer -> no reallocate
    result := p;
    header^.UserAllocatedSize := size;
    exit;
  end
  else
    // size-down and move just the trailing data
    oldavail := size;
  {$ifdef FPCMM_NOMREMAP}
  // no mremap(): reallocate a new block, copy the existing data, free old
  result := _GetMem(new);
  if result <> nil then
  begin
    if new > (MaximumMediumBlockSize - BlockHeaderSize) then
      PLargeBlockHeader(PByte(result) - LargeBlockHeaderSize).UserAllocatedSize := size;
    MoveLarge(p, result, oldavail);
  end;
  _FreeMem(p);
  {$else}
  // remove from current chain list
  LockLargeBlocks;
  prev := header^.PreviousLargeBlockHeader;
  next := header^.NextLargeBlockHeader;
  next.PreviousLargeBlockHeader := prev;
  prev.NextLargeBlockHeader := next;
  LargeBlocksLocked := False;
  // let the Linux Kernel mremap() the memory using its TLB magic
  size := DropMediumAndLargeFlagsMask and header^.BlockSizeAndFlags;
  result := AllocateLargeBlockFrom(new, header, size);
  {$endif FPCMM_NOMREMAP}
end;


{ ********* Main Memory Manager Functions }

procedure LockGetMem; nostackframe; assembler;
asm
  // Can use one of the several arenas reserved for tiny blocks?
  cmp ecx, SizeOf(TTinyBlockTypes)
  jae @NotTinyBlockType
  { ---------- TINY (size<=128B) block lock ---------- }
@LockTinyBlockTypeLoop:
  // Round-Robin attempt to lock of SmallBlockInfo.Tiny[]
  // -> fair distribution among calls to reduce thread contention
  mov edx, NumTinyBlockArenas
@TinyBlockArenaLoop:
  mov eax, SizeOf(TTinyBlockTypes)
  lock xadd dword ptr[r8 + TSmallBlockInfo.TinyCurrentArena], eax
  and eax, (NumTinyBlockArenas * Sizeof(TTinyBlockTypes)) - 1
  add rax, rcx
  lea rbx, [r8 + rax].TSmallBlockInfo.Tiny
  mov eax, $100
  cmp [rbx].TSmallBlockType.BlockTypeLocked, ah
  je @NextTinyBlockArena
  lock cmpxchg [rbx].TSmallBlockType.BlockTypeLocked, ah
  jne @NextTinyBlockArena
@GotLockOnTinyBlockType:
  ret
@NextTinyBlockArena:
  dec edx
  jnz @TinyBlockArenaLoop
  // Also try the default SmallBlockInfo.Small[]
  lea rbx, [r8 + rcx]
  mov eax, $100
  lock cmpxchg [rbx].TSmallBlockType.BlockTypeLocked, ah
  je @GotLockOnTinyBlockType
  // Thread Contention (occurs much less than during _Freemem)
  lock inc dword ptr [rbx].TSmallBlockType.GetmemSleepCount
  push r8
  push rcx
  call Releasecore
  pop rcx
  pop r8
  jmp @LockTinyBlockTypeLoop
  { ---------- SMALL (size<2600) block lock ---------- }
@NotTinyBlockType:
  lea rbx, [r8 + rcx].TSmallBlockInfo.Small
@LockBlockTypeLoopRetry:
  mov r9, SpinSmallGetmemLockCount
@LockBlockTypeLoop:
  // Grab the default block type
  mov eax, $100
  lock cmpxchg [rbx].TSmallBlockType.BlockTypeLocked, ah
  jne @LockNextSmallBlockType
@GotLockOnSmallBlockType:
  ret
@LockNextSmallBlockType:
  // Try up to two next sizes
  add rbx, SizeOf(TSmallBlockType)
  mov eax, $100
  lock cmpxchg [rbx].TSmallBlockType.BlockTypeLocked, ah
  je @GotLockOnSmallBlockType
  pause
  add rbx, SizeOf(TSmallBlockType)
  mov eax, $100
  lock cmpxchg [rbx].TSmallBlockType.BlockTypeLocked, ah
  je @GotLockOnSmallBlockType
  sub rbx, 2 * SizeOf(TSmallBlockType)
  pause
  dec r9
  jnz @LockBlockTypeLoop
   // Block type and two sizes larger are all locked - give up and sleep
  lock inc dword ptr [rbx].TSmallBlockType.GetmemSleepCount
  call Releasecore
  jmp @LockBlockTypeLoopRetry
end;

function _GetMem(size: PtrInt): pointer; nostackframe; assembler;
asm
  {$ifndef MSWINDOWS}
  mov rcx, size
  {$else}
  push rsi
  push rdi
  {$endif MSWINDOWS}
  push rbx
  // Since most allocations are for small blocks, determine the small block type
  lea rbx, [rip + SmallBlockInfo]
  lea rdx, [size + BlockHeaderSize - 1]
  shr rdx, 4 // div SmallBlockGranularity
  // Is it a tiny/small block?
  cmp rcx, (MaximumSmallBlockSize - BlockHeaderSize)
  ja @NotTinySmallBlock
  test rcx, rcx
  jle @VoidSize
  {$ifndef FPCMM_ASSUMEMULTITHREAD}
  mov rax, qword ptr [rbx].TSmallBlockInfo.IsMultiThreadPtr
  {$endif FPCMM_ASSUMEMULTITHREAD}
  // Get the tiny/small TSmallBlockType[] offset in rcx
  movzx ecx, byte ptr [rbx + rdx].TSmallBlockInfo.GetmemLookup
  mov r8, rbx
  shl ecx, 6 // *SizeOf(TSmallBlockType)
  // Get a locked
  {$ifndef FPCMM_ASSUMEMULTITHREAD}
  cmp byte ptr[rax], 0
  jne @CheckTinySmallLock
  add rbx, rcx
  mov byte ptr [rbx].TSmallBlockType.BlockTypeLocked, true
  jmp @GotLockOnSmallBlockType
  {$endif FPCMM_ASSUMEMULTITHREAD}
@CheckTinySmallLock:
  call LockGetMem
  { ---------- TINY/SMALL block registration ---------- }
@GotLockOnSmallBlockType:
  // Get rdx=NextPartiallyFreePool rax=FirstFreeBlock rcx=DropSmallFlagsMask
  inc [rbx].TSmallBlockType.GetmemCount
  mov rdx, [rbx].TSmallBlockType.NextPartiallyFreePool
  mov rax, [rdx].TSmallBlockPoolHeader.FirstFreeBlock
  mov rcx, DropSmallFlagsMask
  // Is there a pool with free blocks?
  cmp rdx, rbx
  je @TrySmallSequentialFeed
  add [rdx].TSmallBlockPoolHeader.BlocksInUse, 1
  // Set the new first free block and the block header
  and rcx, [rax - BlockHeaderSize]
  mov [rdx].TSmallBlockPoolHeader.FirstFreeBlock, rcx
  mov [rax - BlockHeaderSize], rdx
  // Is the chunk now full?
  jz @RemoveSmallPool
  // Unlock the block type and leave
  mov [rbx].TSmallBlockType.BlockTypeLocked, False
@Done:
  pop rbx
  {$ifdef MSWINDOWS}
  pop rdi
  pop rsi
  {$endif MSWINDOWS}
  ret
@VoidSize:
  xor eax, eax
  {$ifdef MSWINDOWS}
  jmp @Done
  {$else}
  pop rbx
  ret
  {$endif MSWINDOWS}
@TrySmallSequentialFeed:
  // Feed a small block sequentially
  mov rdx, [rbx].TSmallBlockType.CurrentSequentialFeedPool
  movzx ecx, [rbx].TSmallBlockType.BlockSize
  add rcx, rax
  // Can another block fit?
  cmp rax, [rbx].TSmallBlockType.MaxSequentialFeedBlockAddress
  ja @AllocateSmallBlockPool
  // Adjust number of used blocks and sequential feed pool
  add [rdx].TSmallBlockPoolHeader.BlocksInUse, 1
  mov [rbx].TSmallBlockType.NextSequentialFeedBlockAddress, rcx
  // Unlock the block type, set the block header and leave
  mov [rbx].TSmallBlockType.BlockTypeLocked, False
  mov [rax - BlockHeaderSize], rdx
  pop rbx
  {$ifdef MSWINDOWS}
  pop rdi
  pop rsi
  {$endif MSWINDOWS}
  ret
@RemoveSmallPool:
  // Pool is full - remove it from the partially free list
  mov rcx, [rdx].TSmallBlockPoolHeader.NextPartiallyFreePool
  mov [rcx].TSmallBlockPoolHeader.PreviousPartiallyFreePool, rbx
  mov [rbx].TSmallBlockType.NextPartiallyFreePool, rcx
  // Unlock the block type and leave
  mov [rbx].TSmallBlockType.BlockTypeLocked, False
  pop rbx
  {$ifdef MSWINDOWS}
  pop rdi
  pop rsi
  {$endif MSWINDOWS}
  ret
@AllocateSmallBlockPool:
  // Access shared information about Medium blocks storage
  lea r10, [rip + MediumBlockInfo]
  mov eax, $100
  lea rcx, [r10 + TMediumBlockInfo.Locked]
lock cmpxchg byte ptr [rcx], ah
  je @MediumLocked1
  call LockMediumBlocks
@MediumLocked1:
  // Are there any available blocks of a suitable size?
  movsx esi, [rbx].TSmallBlockType.AllowedGroupsForBlockPoolBitmap
  and esi, [r10 + TMediumBlockInfo.BinGroupBitmap]
  jz @NoSuitableMediumBlocks
  // Compute rax = bin group number with free blocks, rcx = bin number
  bsf eax, esi
  lea r8, [r10 + TMediumBlockInfo.BinBitmaps]
  lea r9, [rax * 4]
  mov rcx, [r8 + r9]
  bsf ecx, ecx
  lea rcx, [rcx + r9 * 8]
  // Set rdi = @bin, rsi = free block
  lea rsi, [rcx * 8] // SizeOf(TMediumBlockBin) = 16
  lea rdi, [r10 + TMediumBlockInfo.Bins + rsi * 2]
  mov rsi, TMediumFreeBlock[rdi].NextFreeBlock
  // Remove the first block from the linked list (LIFO)
  mov rdx, TMediumFreeBlock[rsi].NextFreeBlock
  mov TMediumFreeBlock[rdi].NextFreeBlock, rdx
  mov TMediumFreeBlock[rdx].PreviousFreeBlock, rdi
  // Is this bin now empty?
  cmp rdi, rdx
  jne @MediumBinNotEmpty
  // rbx = block type, r8 = @MediumBlockBinBitmaps, rax = bin group number,
  // r9 = bin group number * 4, rcx = bin number, rdi = @bin, rsi = free block
  // Flag this bin as empty
  mov edx, -2
  rol edx, cl
  and [r8 + r9], edx
  jnz @MediumBinNotEmpty
  // Flag the group as empty
  btr [r10 + TMediumBlockInfo.BinGroupBitmap], eax
@MediumBinNotEmpty:
  // rsi = free block, rbx = block type
  // Get the size of the available medium block in edi
  mov rdi, DropMediumAndLargeFlagsMask
  and rdi, [rsi - BlockHeaderSize]
  cmp edi, MaximumSmallBlockPoolSize
  jb @UseWholeBlock
  // Split the block: new block size is the optimal size
  mov edx, edi
  movzx edi, [rbx].TSmallBlockType.OptimalBlockPoolSize
  sub edx, edi
  lea rcx, [rsi + rdi]
  lea rax, [rdx + IsMediumBlockFlag + IsFreeBlockFlag]
  mov [rcx - BlockHeaderSize], rax
  // Store the size of the second split as the second last pointer
  mov [rcx + rdx - 16], rdx
  // Put the remainder in a bin (it will be big enough)
  call InsertMediumBlockIntoBin // rcx=APMediumFreeBlock, edx=AMediumBlockSize
  jmp @GotMediumBlock
@NoSuitableMediumBlocks:
  // Check the sequential feed medium block pool for space
  movzx ecx, [rbx].TSmallBlockType.MinimumBlockPoolSize
  mov edi, [r10 + TMediumBlockInfo.SequentialFeedBytesLeft]
  cmp edi, ecx
  jb @AllocateNewSequentialFeed
  // Get the address of the last block that was fed
  mov rsi, [r10 + TMediumBlockInfo.LastSequentiallyFed]
  // Enough sequential feed space: Will the remainder be usable?
  movzx ecx, [rbx].TSmallBlockType.OptimalBlockPoolSize
  lea rdx, [rcx + MinimumMediumBlockSize]
  cmp edi, edx
  cmovb edi, ecx
  sub rsi, rdi
  // Update the sequential feed parameters
  sub [r10 + TMediumBlockInfo.SequentialFeedBytesLeft], edi
  mov [r10 + TMediumBlockInfo.LastSequentiallyFed], rsi
  jmp @GotMediumBlock
@AllocateNewSequentialFeed:
  // Use the optimal size for allocating this small block pool
  movzx size, word ptr [rbx].TSmallBlockType.OptimalBlockPoolSize
  push size // use "size" variable = first argument in current ABI call
  call AllocNewSequentialFeedMediumPool
  pop rdi  // restore edi=blocksize and r10=MediumBlockInfo
  lea r10, [rip + MediumBlockInfo]
  mov rsi, rax
  test rax, rax
  jnz @GotMediumBlock // rsi=freeblock rbx=blocktype edi=blocksize
  mov [r10 + TMediumBlockInfo.Locked], al
  mov [rbx].TSmallBlockType.BlockTypeLocked, al
  {$ifdef MSWINDOWS}
  jmp @Done
  {$else}
  pop rbx
  ret
  {$endif MSWINDOWS}
@UseWholeBlock:
  // rsi = free block, rbx = block type, edi = block size
  // Mark this block as used in the block following it
  and byte ptr [rsi + rdi - BlockHeaderSize], not PreviousMediumBlockIsFreeFlag
@GotMediumBlock:
  // rsi = free block, rbx = block type, edi = block size
  // Set the size and flags for this block
  lea rcx, [rdi + IsMediumBlockFlag + IsSmallBlockPoolInUseFlag]
  mov [rsi - BlockHeaderSize], rcx
  // Unlock medium blocks and setup the block pool
  xor eax, eax
  mov [r10 + TMediumBlockInfo.Locked], al
  mov TSmallBlockPoolHeader[rsi].BlockType, rbx
  mov TSmallBlockPoolHeader[rsi].FirstFreeBlock, rax
  mov TSmallBlockPoolHeader[rsi].BlocksInUse, 1
  mov [rbx].TSmallBlockType.CurrentSequentialFeedPool, rsi
  // Return the pointer to the first block, compute next/last block addresses
  lea rax, [rsi + SmallBlockPoolHeaderSize]
  movzx ecx, [rbx].TSmallBlockType.BlockSize
  lea rdx, [rax + rcx]
  mov [rbx].TSmallBlockType.NextSequentialFeedBlockAddress, rdx
  add rdi, rsi
  sub rdi, rcx
  mov [rbx].TSmallBlockType.MaxSequentialFeedBlockAddress, rdi
  // Unlock the small block type, set header and leave
  mov [rbx].TSmallBlockType.BlockTypeLocked, False
  mov [rax - BlockHeaderSize], rsi
  pop rbx
  {$ifdef MSWINDOWS}
  pop rdi
  pop rsi
  {$endif MSWINDOWS}
  ret
  { ---------- MEDIUM block allocation ---------- }
@NotTinySmallBlock:
  // Do we need a Large block?
  lea r10, [rip + MediumBlockInfo]
  cmp rcx, (MaximumMediumBlockSize - BlockHeaderSize)
  ja @IsALargeBlockRequest
  // Get the bin size for this block size (rounded up to the next bin size)
  lea rbx, [rcx + MediumBlockGranularity - 1 + BlockHeaderSize - MediumBlockSizeOffset]
  lea rcx, [r10 + TMediumBlockInfo.Locked]
  and ebx, -MediumBlockGranularity
  add ebx, MediumBlockSizeOffset
  mov eax, $100
lock cmpxchg byte ptr [rcx], ah
  je @MediumLocked2
  call LockMediumBlocks
@MediumLocked2:
  // Compute ecx = bin number in ecx and edx = group number
  lea rdx, [rbx - MinimumMediumBlockSize]
  mov ecx, edx
  shr edx, 8 + 5
  shr ecx, 8
  mov eax, -1
  shl eax, cl
  lea r8, [r10 + TMediumBlockInfo.BinBitmaps]
  and eax, [r8 + rdx * 4]
  jz @GroupIsEmpty
  and ecx, -32
  bsf eax, eax
  or ecx, eax
  jmp @GotBinAndGroup
@GroupIsEmpty:
  // Try all groups greater than this group
  mov eax, -2
  mov ecx, edx
  shl eax, cl
  and eax, [r10 + TMediumBlockInfo.BinGroupBitmap]
  jz @TrySequentialFeedMedium
  // There is a suitable group with enough space
  bsf edx, eax
  mov eax, [r8 + rdx * 4]
  bsf ecx, eax
  mov eax, edx
  shl eax, 5
  or ecx, eax
  jmp @GotBinAndGroup
@TrySequentialFeedMedium:
  mov ecx, [r10 + TMediumBlockInfo.SequentialFeedBytesLeft]
  // Can block be fed sequentially?
  sub ecx, ebx
  jc @AllocateNewSequentialFeedForMedium
  // Get the block address, store remaining bytes, set the flags and unlock
  mov rax, [r10 + TMediumBlockInfo.LastSequentiallyFed]
  sub rax, rbx
  mov [r10 + TMediumBlockInfo.LastSequentiallyFed], rax
  mov [r10 + TMediumBlockInfo.SequentialFeedBytesLeft], ecx
  or rbx, IsMediumBlockFlag
  mov [rax - BlockHeaderSize], rbx
  mov byte ptr [r10 + TMediumBlockInfo.Locked], false
  {$ifdef MSWINDOWS}
  jmp @Done
  {$else}
  pop rbx
  ret
  {$endif MSWINDOWS}
@AllocateNewSequentialFeedForMedium:
  mov size, rbx // 'size' variable is the first argument register in ABI call
  call AllocNewSequentialFeedMediumPool
  mov byte [rip + MediumBlockInfo.Locked], false // r10 has been overwritten
  {$ifdef MSWINDOWS}
  jmp @Done
  {$else}
  pop rbx
  ret
  {$endif MSWINDOWS}
@GotBinAndGroup:
  // ebx = block size, ecx = bin number, edx = group number
  // Compute rdi = @bin, rsi = free block
  lea rax, [rcx + rcx]
  lea rdi, [r10 + TMediumBlockInfo.Bins + rax * 8]
  mov rsi, TMediumFreeBlock[rdi].NextFreeBlock
  // Remove the first block from the linked list (LIFO)
  mov rax, TMediumFreeBlock[rsi].NextFreeBlock
  mov TMediumFreeBlock[rdi].NextFreeBlock, rax
  mov TMediumFreeBlock[rax].PreviousFreeBlock, rdi
  // Is this bin now empty?
  cmp rdi, rax
  jne @MediumBinNotEmptyForMedium
  // edx = bin group number, ecx = bin number, rdi = @bin, rsi = free block, ebx = block size
  // Flag this bin and group as empty
  mov eax, -2
  rol eax, cl
  and [r10 + TMediumBlockInfo.BinBitmaps + rdx * 4], eax
  jnz @MediumBinNotEmptyForMedium
  btr [r10 + TMediumBlockInfo.BinGroupBitmap], edx
@MediumBinNotEmptyForMedium:
  // rsi = free block, ebx = block size
  // Get rdi = size of the available medium block, rdx = second split size
  mov rdi, DropMediumAndLargeFlagsMask
  and rdi, [rsi - BlockHeaderSize]
  mov edx, edi
  sub edx, ebx
  jz @UseWholeBlockForMedium
  // Split the block in two
  lea rcx, [rsi + rbx]
  lea rax, [rdx + IsMediumBlockFlag + IsFreeBlockFlag]
  mov [rcx - BlockHeaderSize], rax
  // Store the size of the second split as the second last pointer
  mov [rcx + rdx - 16], rdx
  // Put the remainder in a bin
  cmp edx, MinimumMediumBlockSize
  jb @GotMediumBlockForMedium
  call InsertMediumBlockIntoBin // rcx=APMediumFreeBlock, edx=AMediumBlockSize
  jmp @GotMediumBlockForMedium
@UseWholeBlockForMedium:
  // Mark this block as used in the block following it
  and byte ptr [rsi + rdi - BlockHeaderSize], not PreviousMediumBlockIsFreeFlag
@GotMediumBlockForMedium:
  // Set the size and flags for this block
  lea rcx, [rbx + IsMediumBlockFlag]
  mov [rsi - BlockHeaderSize], rcx
  // Unlock medium blocks and leave
  mov byte ptr[r10 + TMediumBlockInfo.Locked], false
  mov rax, rsi
  {$ifdef MSWINDOWS}
  jmp @Done
  {$else}
  pop rbx
  ret
  {$endif MSWINDOWS}
  { ---------- LARGE block allocation ---------- }
@IsALargeBlockRequest:
  xor rax, rax
  test rcx, rcx
  js @DoneLarge
  // Note: size is still in the rcx/rdi first param register
  call AllocateLargeBlock
@DoneLarge:
  {$ifdef MSWINDOWS}
  jmp @Done
  {$else}
  pop rbx
  {$endif MSWINDOWS}
end;

procedure LockFreeMem; nostackframe; assembler;
asm
@LockBlockTypeLoop:
  // Spin to grab the block type (don't try too long due to contention)
  mov r8d, SpinSmallFreememLockCount
@SpinLockBlockType:
  pause
  dec r8d
  jz @LockBlockTypeSleep
  cmp byte ptr [rbx].TSmallBlockType.BlockTypeLocked, 1
  je @SpinLockBlockType
  mov eax, $100
  lock cmpxchg [rbx].TSmallBlockType.BlockTypeLocked, ah
  jne @SpinLockBlockType
  ret
@LockBlockTypeSleep:
  // Couldn't grab the block type - sleep and try again
  lock inc dword ptr [rbx].TSmallBlockType.FreeMemSleepCount
  push rcx
  call Releasecore
  pop rcx
  mov rdx, [rcx - BlockHeaderSize]
  jmp @LockBlockTypeLoop
end;

function _FreeMem(P: pointer): PtrInt; nostackframe; assembler;
asm
  {$ifdef MSWINDOWS}
  push rsi
  {$else}
  mov rcx, P
  {$endif MSWINDOWS}
  push rbx
  test P, P
  jz @VoidPointer
  {$ifdef FPCMM_REPORTMEMORYLEAKS}
  mov qword ptr[P], 0 // e.g. reset TObject VMT or string/dynamic array header
  {$endif FPCMM_REPORTMEMORYLEAKS}
  mov rdx, [P - BlockHeaderSize]
  // Is it a small block in use?
  test dl, IsFreeBlockFlag + IsMediumBlockFlag + IsLargeBlockFlag
  jnz @NotSmallBlockInUse
  // Get the small block type in rbx and try to grab it
  mov rbx, [rdx].TSmallBlockPoolHeader.BlockType
  {$ifndef FPCMM_ASSUMEMULTITHREAD}
  mov rax, qword ptr [rip + SmallBlockInfo].TSmallBlockInfo.IsMultiThreadPtr
  cmp byte ptr[rax], 0
  jne @CheckTinySmallLock
  mov byte ptr [rbx].TSmallBlockType.BlockTypeLocked, true
  jmp @GotLockOnSmallBlockType
@CheckTinySmallLock:
  {$endif FPCMM_ASSUMEMULTITHREAD}
  mov eax, $100
lock cmpxchg [rbx].TSmallBlockType.BlockTypeLocked, ah
  je @GotLockOnSmallBlockType
  call LockFreeMem
@GotLockOnSmallBlockType:
  // rdx = @SmallBlockPoolHeader, rcx = P, rbx = @SmallBlockType
  // Adjust number of blocks in use, set rax = old first free block
  inc [rbx].TSmallBlockType.FreememCount
  mov rax, [rdx].TSmallBlockPoolHeader.FirstFreeBlock
  sub [rdx].TSmallBlockPoolHeader.BlocksInUse, 1
  jz @PoolIsNowEmpty
  // Store this as the new first free block
  mov [rdx].TSmallBlockPoolHeader.FirstFreeBlock, rcx
  // Store the previous first free block as the block header
  lea r8, [rax + IsFreeBlockFlag]
  mov [rcx - BlockHeaderSize], r8
  // Was the pool full?
  test rax, rax
  jnz @SmallPoolWasNotFull
  // Insert the pool back into the linked list if it was full
  mov rcx, [rbx].TSmallBlockType.NextPartiallyFreePool
  mov [rdx].TSmallBlockPoolHeader.PreviousPartiallyFreePool, rbx
  mov [rdx].TSmallBlockPoolHeader.NextPartiallyFreePool, rcx
  mov [rcx].TSmallBlockPoolHeader.PreviousPartiallyFreePool, rdx
  mov [rbx].TSmallBlockType.NextPartiallyFreePool, rdx
@SmallPoolWasNotFull:
  // Unlock the block type and leave
  mov [rbx].TSmallBlockType.BlockTypeLocked, 0
@VoidPointer:
  xor eax, eax
  pop rbx
  {$ifdef MSWINDOWS}
  pop rsi
  {$endif MSWINDOWS}
  ret
@PoolIsNowEmpty:
  // FirstFreeBlock=nil means it is the sequential feed pool with a single block
  test rax, rax
  jz @IsSequentialFeedPool
  // Pool is now empty: Remove it from the linked list and free it
  mov rax, [rdx].TSmallBlockPoolHeader.PreviousPartiallyFreePool
  mov rcx, [rdx].TSmallBlockPoolHeader.NextPartiallyFreePool
  mov TSmallBlockPoolHeader[rax].NextPartiallyFreePool, rcx
  mov [rcx].TSmallBlockPoolHeader.PreviousPartiallyFreePool, rax
  xor eax, eax
  // Is this the sequential feed pool? If so, stop sequential feeding
  cmp [rbx].TSmallBlockType.CurrentSequentialFeedPool, rdx
  jne @NotSequentialFeedPool
@IsSequentialFeedPool:
  mov [rbx].TSmallBlockType.MaxSequentialFeedBlockAddress, rax
@NotSequentialFeedPool:
  // Unlock the small block type and release this pool
  mov [rbx].TSmallBlockType.BlockTypeLocked, al
  mov rcx, rdx
  mov rdx, [rdx - BlockHeaderSize]
  jmp @FreeMediumBlock
  {---------------------Medium blocks------------------------------}
@NotSmallBlockInUse:
  // Not a small block in use: is it a medium or large block?
  test dl, IsFreeBlockFlag + IsLargeBlockFlag
  jnz @NotASmallOrMediumBlock
@FreeMediumBlock:
  // Drop the flags, free rax=medium block, set rbx=block size
  lea r10, [rip + MediumBlockInfo]
  and rdx, DropMediumAndLargeFlagsMask
  mov rbx, rdx
  mov rsi, rcx
  lea rcx, [r10 + TMediumBlockInfo.Locked]
  mov eax, $100
lock cmpxchg byte ptr [rcx], ah
  je   @MediumBlocksLocked
  call LockMediumBlocks
@MediumBlocksLocked:
  // Get rcx = next block size and flags
  mov rcx, [rsi + rbx - BlockHeaderSize]
  // Can we combine this block with the next free block?
  test qword ptr [rsi + rbx - BlockHeaderSize], IsFreeBlockFlag
  jnz @NextBlockIsFree
  // Set the "PreviousIsFree" flag in the next block
  or rcx, PreviousMediumBlockIsFreeFlag
  mov [rsi + rbx - BlockHeaderSize], rcx
@NextBlockChecked:
  // Re-read the flags and try to combine with previous free block
  test byte ptr [rsi - BlockHeaderSize], PreviousMediumBlockIsFreeFlag
  jnz @PreviousBlockIsFree
@PreviousBlockChecked:
  // Check if entire medium block pool is free
  cmp ebx, (MediumBlockPoolSize - MediumBlockPoolHeaderSize)
  je @EntireMediumPoolFree
@BinFreeMediumBlock:
  // Store size of the block, flags and trailing size marker and insert into bin
  lea rax, [rbx + IsMediumBlockFlag + IsFreeBlockFlag]
  mov [rsi - BlockHeaderSize], rax
  mov [rsi + rbx - 16], rbx
  mov rcx, rsi
  mov rdx, rbx
  call InsertMediumBlockIntoBin // rcx=APMediumFreeBlock, edx=AMediumBlockSize
  xor eax, eax
  // Unlock medium blocks and leave
  mov [r10 + TMediumBlockInfo.Locked], al
  jmp @Done
@NextBlockIsFree:
  // Get rax = next block address, rbx = end of the block
  lea rax, [rsi + rbx]
  and rcx, DropMediumAndLargeFlagsMask
  add rbx, rcx
  // Was the block binned?
  cmp rcx, MinimumMediumBlockSize
  jb @NextBlockChecked
  mov rcx, rax
  call RemoveMediumFreeBlock // rcx = APMediumFreeBlock
  jmp @NextBlockChecked
@PreviousBlockIsFree:
  // Get rcx/rsi =  size/point of the previous free block, rbx = new block end
  mov rcx, [rsi - 16]
  sub rsi, rcx
  add rbx, rcx
  // Remove the previous block from the linked list
  cmp ecx, MinimumMediumBlockSize
  jb @PreviousBlockChecked
  mov rcx, rsi
  call RemoveMediumFreeBlock // rcx = APMediumFreeBlock
  jmp @PreviousBlockChecked
@EntireMediumPoolFree:
  // Ensure current sequential feed pool is free
  cmp dword ptr [r10 + TMediumBlockInfo.SequentialFeedBytesLeft], MediumBlockPoolSize - MediumBlockPoolHeaderSize
  jne @MakeEmptyMediumPoolSequentialFeed
  // Remove this medium block pool from the linked list stored in its header
  sub rsi, MediumBlockPoolHeaderSize
  mov rax, TMediumBlockPoolHeader[rsi].PreviousMediumBlockPoolHeader
  mov rdx, TMediumBlockPoolHeader[rsi].NextMediumBlockPoolHeader
  mov TMediumBlockPoolHeader[rax].NextMediumBlockPoolHeader, rdx
  mov TMediumBlockPoolHeader[rdx].PreviousMediumBlockPoolHeader, rax
  // Unlock medium blocks and free the block pool
  mov [r10 + TMediumBlockInfo.Locked], false
  mov P, rsi
  call FreeMedium
  xor eax, eax // success
  jmp @Done
@MakeEmptyMediumPoolSequentialFeed:
  // Get rbx = end-marker block, and recycle the current sequential feed pool
  lea rbx, [rsi + MediumBlockPoolSize - MediumBlockPoolHeaderSize]
  call BinMediumSequentialFeedRemainder
  // Set this medium pool up as the new sequential feed pool, unlock and leave
  mov qword ptr [rbx - BlockHeaderSize], IsMediumBlockFlag
  mov dword ptr [r10 + TMediumBlockInfo.SequentialFeedBytesLeft], MediumBlockPoolSize - MediumBlockPoolHeaderSize
  mov [r10 + TMediumBlockInfo.LastSequentiallyFed], rbx
  xor eax, eax
  mov [r10 + TMediumBlockInfo.Locked], al
  jmp @Done
@NotASmallOrMediumBlock:
  // If it is not an attempt to free a block twice, release as large block
  mov eax, -1
  test dl, IsFreeBlockFlag + IsMediumBlockFlag
  jnz @Done
  call FreeLargeBlock // P is still in rcx/rdi first param register
@Done:
  pop rbx
  {$ifdef MSWINDOWS}
  pop rsi
  {$endif MSWINDOWS}
end;

// warning: FPC signature is not the same than Delphi: requires "var P"
function _ReallocMem(var P: pointer; Size: PtrInt): pointer; nostackframe; assembler;
asm
  mov rdx, Size
  {$ifdef MSWINDOWS}
  push rdi
  push rsi
  {$endif MSWINDOWS}
  push rbx
  push r14
  push P // for assignement in @Done
  mov r14, qword ptr[P]
  test rdx, rdx
  jz @VoidSize  // ReallocMem(P,0)=FreeMem(P)
  test r14, r14
  jz @GetMemMoveFreeMem // ReallocMem(nil,Size)=GetMem(Size)
  mov rcx, [r14 - BlockHeaderSize]
  test cl, IsFreeBlockFlag + IsMediumBlockFlag + IsLargeBlockFlag
  jnz @NotASmallBlock
  { -------------- TINY/SMALL block ------------- }
  // Get rbx = block type, rcx = available size
  mov rbx, [rcx].TSmallBlockPoolHeader.BlockType
  movzx ecx, [rbx].TSmallBlockType.BlockSize
  sub ecx, BlockHeaderSize
  cmp rcx, rdx
  jb @SmallUpsize
  // Downsize or small growup with enough space: reallocate only if need
  lea rbx, [rdx * 4 + SmallBlockDownsizeCheckAdder]
  cmp ebx, ecx
  jb @GetMemMoveFreeMem // r14=P rdx=size
  mov rax, r14 // keep original pointer
  pop rcx
  pop r14
  pop rbx
  {$ifdef MSWINDOWS}
  pop rsi
  pop rdi
  {$endif MSWINDOWS}
  ret
@VoidSize:
  push rdx    // to set P=nil
  jmp @DoFree // ReallocMem(P,0)=FreeMem(P)
@SmallUpsize:
  // State: r14=pointer, rdx=NewSize, rcx=CurrentBlockSize, rbx=CurrentBlockType
  // Small blocks always grow with at least 100% + SmallBlockUpsizeAdder bytes
  lea P, qword ptr[rcx + rcx + SmallBlockUpsizeAdder]
  movzx ebx, [rbx].TSmallBlockType.BlockSize
  sub ebx, BlockHeaderSize + 8
  // r14=pointer, P=BlockSize, rdx=NewSize, rbx=OldSize-8
@AdjustGetMemMoveFreeMem:
  // New allocated size is the maximum of the requested size and the minimum upsize
  xor rax, rax
  sub P, rdx
  adc rax, -1
  and P, rax
  add P, rdx
  push rdx
  call _GetMem
  pop rdx
  test rax, rax
  jz @Done
  cmp rdx, MaximumMediumBlockSize - BlockHeaderSize
  jbe @MoveFreeMem // rax=New r14=P rbx=size-8
  // Store the user requested size for large block
  mov [rax - 16], rdx
  jmp @MoveFreeMem // rax=New r14=P rbx=size-8
@GetMemMoveFreeMem:
  // reallocate copy and free: r14=P rdx=size
  mov rbx, rdx
  mov P, rdx // P is the proper first argument register
  call _GetMem
  test rax, rax
  jz @Done
  test r14, r14 // ReallocMem(nil,Size)=GetMem(Size)
  jz @Done
  sub rbx, 8
@MoveFreeMem:
  // copy and free: rax=New r14=P rbx=size-8
  push rax
  lea rcx, [r14 + rbx]
  lea rdx, [rax + rbx]
  neg rbx
  jns @MoveLast8
  align 16
@MoveBy16:
  movaps xmm0, oword ptr [rcx + rbx]
  movaps oword ptr [rdx + rbx], xmm0
  add rbx, 16
  js @MoveBy16
@MoveLast8:
  mov rax, qword ptr [rcx + rbx]
  mov qword ptr [rdx + rbx], rax
@DoFree:
  mov P, r14
  call _FreeMem
  pop rax
@Done:
  pop rcx
  pop r14
  pop rbx
  {$ifdef MSWINDOWS}
  pop rsi
  pop rdi
  {$endif MSWINDOWS}
  mov qword ptr[rcx], rax // store new pointer in var P
  ret
@NotASmallBlock:
  // Is this a medium block or a large block?
  test cl, IsFreeBlockFlag + IsLargeBlockFlag
  jnz @PossibleLargeBlock
  { -------------- MEDIUM block ------------- }
  // rcx = Current Size + Flags, r14 = P, rdx = Requested Size, r10 = MediumBlockInfo
  lea r10, [rip + MediumBlockInfo]
  mov rbx, rcx
  and ecx, DropMediumAndLargeFlagsMask
  lea rdi, [r14 + rcx]
  sub ecx, BlockHeaderSize
  and ebx, ExtractMediumAndLargeFlagsMask
  // Is it an upsize or a downsize?
  cmp rdx, rcx
  ja @MediumBlockUpsize
  // rcx = Current Block Size - BlockHeaderSize, rbx = Current Block Flags,
  // rdi = @Next Block, r14 = P, rdx = Requested Size
  // Downsize relloacate and move data only if less than half the current size
  lea rsi, [rdx + rdx]
  cmp rsi, rcx
  jb @MediumMustDownsize
@MediumNoResize:
  mov rax, r14
  jmp @Done
@MediumMustDownsize:
  // In-place downsize? Ensure not smaller than MinimumMediumBlockSize
  cmp edx, MinimumMediumBlockSize - BlockHeaderSize
  jae @MediumBlockInPlaceDownsize
  // Need to move to another Medium block pool, or into a Small block?
  cmp edx, MediumInPlaceDownsizeLimit
  jb @GetMemMoveFreeMem
  // No need to realloc: resize in-place (if not already at the minimum size)
  mov edx, MinimumMediumBlockSize - BlockHeaderSize
  cmp ecx, edx
  jna @MediumNoResize
@MediumBlockInPlaceDownsize:
  // Round up to the next medium block size
  lea rsi, [rdx + BlockHeaderSize + MediumBlockGranularity - 1 - MediumBlockSizeOffset]
  and rsi, -MediumBlockGranularity
  add rsi, MediumBlockSizeOffset
  // Get the size of the second split
  add ecx, BlockHeaderSize
  sub ecx, esi
  mov ebx, ecx
  // Lock the medium blocks
  lea rcx, [r10 + TMediumBlockInfo.Locked]
  mov eax, $100
lock cmpxchg byte ptr [rcx], ah
  je   @MediumBlocksLocked1
  call LockMediumBlocks
@MediumBlocksLocked1:
  mov ecx, ebx
  // Reread the flags - may have changed before medium blocks could be locked
  mov rbx, ExtractMediumAndLargeFlagsMask
  and rbx, [r14 - BlockHeaderSize]
@DoMediumInPlaceDownsize:
  // Set the new size in header, and get rbx = second split size
  or rbx, rsi
  mov [r14 - BlockHeaderSize], rbx
  mov ebx, ecx
  // If the next block is used, flag its previous block as free
  mov rdx, [rdi - BlockHeaderSize]
  test dl, IsFreeBlockFlag
  jnz @MediumDownsizeNextBlockFree
  or rdx, PreviousMediumBlockIsFreeFlag
  mov [rdi - BlockHeaderSize], rdx
  jmp @MediumDownsizeDoSplit
@MediumDownsizeNextBlockFree:
  // If the next block is free, combine both
  mov rcx, rdi
  and rdx, DropMediumAndLargeFlagsMask
  add rbx, rdx
  add rdi, rdx
  cmp edx, MinimumMediumBlockSize
  jb @MediumDownsizeDoSplit
  call RemoveMediumFreeBlock // rcx=APMediumFreeBlock
@MediumDownsizeDoSplit:
  // Store the trailing size field and free part header
  mov [rdi - 16], rbx
  lea rcx, [rbx + IsMediumBlockFlag + IsFreeBlockFlag];
  mov [r14 + rsi - BlockHeaderSize], rcx
  // Bin this free block (if worth it)
  cmp rbx, MinimumMediumBlockSize
  jb @MediumBlockDownsizeDone
  lea rcx, [r14 + rsi]
  mov rdx, rbx
  call InsertMediumBlockIntoBin // rcx=APMediumFreeBlock, edx=AMediumBlockSize
@MediumBlockDownsizeDone:
  // Unlock the medium blocks, and leave with the new pointer
  mov byte ptr [r10 + TMediumBlockInfo.Locked], False
  mov rax, r14
  jmp @Done
@MediumBlockUpsize:
  // ecx = Current Block Size - BlockHeaderSize, bl = Current Block Flags,
  // rdi = @Next Block, r14 = P, rdx = Requested Size
  // Try to make in-place upsize
  mov rax, [rdi - BlockHeaderSize]
  test al, IsFreeBlockFlag
  jz @CannotUpsizeMediumBlockInPlace
  // Get rax = available size, rsi = available size with the next block
  and rax, DropMediumAndLargeFlagsMask
  lea rsi, [rax + rcx]
  cmp rdx, rsi
  ja @CannotUpsizeMediumBlockInPlace
  // Grow into the next block
  mov rbx, rcx
  lea rcx, [r10 + TMediumBlockInfo.Locked]
  mov eax, $100
lock cmpxchg byte ptr [rcx], ah
  je   @MediumBlocksLocked2
  mov rsi, rdx
  call LockMediumBlocks
  mov rdx, rsi
@MediumBlocksLocked2:
  // Re-read info once locked, and ensure next block is still free
  mov rcx, rbx
  mov rbx, ExtractMediumAndLargeFlagsMask
  and rbx, [r14 - BlockHeaderSize]
  mov rax, [rdi - BlockHeaderSize]
  test al, IsFreeBlockFlag
  jz @NextMediumBlockChanged
  and eax, DropMediumAndLargeFlagsMask
  lea rsi, [rax + rcx]
  cmp rdx, rsi
  ja @NextMediumBlockChanged
@DoMediumInPlaceUpsize:
  // Bin next free block (if worth it)
  cmp eax, MinimumMediumBlockSize
  jb @MediumInPlaceNoNextRemove
  push rcx
  push rdx
  mov rcx, rdi
  call RemoveMediumFreeBlock // rcx=APMediumFreeBlock
  pop rdx
  pop rcx
@MediumInPlaceNoNextRemove:
  // Medium blocks grow a minimum of 25% in in-place upsizes
  mov eax, ecx
  shr eax, 2
  add eax, ecx
  // Get the maximum of the requested size and the minimum growth size
  xor edi, edi
  sub eax, edx
  adc edi, -1
  and eax, edi
  // Round up to the nearest block size granularity
  lea rax, [rax + rdx + BlockHeaderSize + MediumBlockGranularity - 1 - MediumBlockSizeOffset]
  and eax, -MediumBlockGranularity
  add eax, MediumBlockSizeOffset
  // Calculate the size of the second split and check if it fits
  lea rdx, [rsi + BlockHeaderSize]
  sub edx, eax
  ja @MediumInPlaceUpsizeSplit
  // Grab the whole block: Mark it as used in the next block, and adjust size
  and qword ptr [r14 + rsi], not PreviousMediumBlockIsFreeFlag
  add rsi, BlockHeaderSize
  jmp @MediumUpsizeInPlaceDone
@MediumInPlaceUpsizeSplit:
  // Store the size of the second split as the second last pointer
  mov [r14 + rsi - BlockHeaderSize], rdx
  // Set the second split header
  lea rdi, [rdx + IsMediumBlockFlag + IsFreeBlockFlag]
  mov [r14 + rax - BlockHeaderSize], rdi
  mov rsi, rax
  cmp edx, MinimumMediumBlockSize
  jb @MediumUpsizeInPlaceDone
  lea rcx, [r14 + rax]
  call InsertMediumBlockIntoBin // rcx=APMediumFreeBlock, edx=AMediumBlockSize
@MediumUpsizeInPlaceDone:
  // No need to move data at upsize: set the size and flags for this block
  or rsi, rbx
  mov [r14 - BlockHeaderSize], rsi
  mov byte ptr [r10 + TMediumBlockInfo.Locked], False
  mov rax, r14
  jmp @Done
@NextMediumBlockChanged:
  // The next block changed during lock: reallocate and move data
  mov byte ptr [r10 + TMediumBlockInfo.Locked], False
@CannotUpsizeMediumBlockInPlace:
  // rcx=OldSize-8, rdx=NewSize
  mov rbx, rcx
  mov eax, ecx
  shr eax, 2
  lea P, qword ptr [rcx + rax] // BlockSize = OldSize+25%
  jmp @AdjustGetMemMoveFreeMem // P=BlockSize, rdx=NewSize, rbx=OldSize-8
@PossibleLargeBlock:
  { -------------- LARGE block ------------- }
  test cl, IsFreeBlockFlag + IsMediumBlockFlag
  jnz @Error
  {$ifdef MSWINDOWS}
  mov rcx, r14
  {$else}
  mov rdi, r14
  mov rsi, rdx
  {$endif MSWINDOWS}
  call ReallocateLargeBlock // with restored proper registers
  jmp @Done
@Error:
  xor eax, eax
  jmp @Done
end;

function _AllocMem(Size: PtrInt): pointer; nostackframe; assembler;
asm
  push rbx
  // Get rbx = size rounded down to the previous multiple of SizeOf(pointer)
  lea rbx, [Size - 1]
  and rbx, -8
  call _GetMem
  // Could a block be allocated? rcx = 0 if yes, -1 if no
  cmp rax, 1
  sbb rcx, rcx
  // Point rdx to the last pointer
  lea rdx, [rax + rbx]
  // Compute Size (1..8 doesn't need to enter the SSE2 loop)
  or rbx, rcx
  jz @ClearLastQWord
  // Large blocks from mmap/VirtualAlloc are already zero filled
  cmp rbx, MaximumMediumBlockSize - BlockHeaderSize
  jae @Done
  neg rbx
  pxor xmm0, xmm0
  align 16
@FillLoop:
  movaps oword ptr [rdx + rbx], xmm0 // non-temporal movntdq not needed (<256KB)
  add rbx, 16
  js @FillLoop
@ClearLastQWord:
  xor rcx, rcx
  mov qword ptr [rdx], rcx
@Done:
  pop rbx
end;

function _MemSize(P: pointer): PtrUInt;
begin
  // AFAIK used only by fpc_AnsiStr_SetLength() in RTL
  P := PPointer(PByte(P) - BlockHeaderSize)^;
  if (PtrUInt(P) and (IsMediumBlockFlag or IsLargeBlockFlag)) = 0 then
    result := PSmallBlockPoolHeader(PtrUInt(P) and DropSmallFlagsMask).
      BlockType.BlockSize - BlockHeaderSize
  else
  begin
    result := (PtrUInt(P) and DropMediumAndLargeFlagsMask) - BlockHeaderSize;
    if (PtrUInt(P) and IsMediumBlockFlag) = 0 then
      dec(result, LargeBlockHeaderSize);
  end;
end;

function _FreeMemSize(P: pointer; size: PtrInt): PtrInt;
begin
  // should return the chunk size - only used by heaptrc
  if size <> 0 then
  begin
    result := _MemSize(P);
    _FreeMem(p);
  end
  else
    result := 0;
end;


{ ********* Information Gathering }

{$ifdef FPCMM_STANDALONE}

procedure Assert(flag: boolean);
begin
end;

{$else}

function _GetHeapStatus: THeapStatus;
begin
  FillChar(result, sizeof(result), 0);
end;

function _GetFPCHeapStatus: TFPCHeapStatus;
begin
  FillChar(result, sizeof(result), 0);
end;

function K(i: PtrUInt): shortstring;
var
  tmp: string[1];
begin
  if i >= 1 shl 40 then
  begin
    i := i shr 40;
    tmp := 'T';
  end
  else
  if i >= 1 shl 30 then
  begin
    i := i shr 30;
    tmp := 'G';
  end
  else
  if i >= 1 shl 20 then
  begin
    i := i shr 20;
    tmp := 'M';
  end
  else
  if i >= 1 shl 10 then
  begin
    i := i shr 10;
    tmp := 'K';
  end
  else
    tmp := '';
  str(i, result);
  result := result + tmp;
end;

{$I-}

procedure WriteHeapStatusDetail(const arena: TMMStatusArena;
  const name: shortstring);
begin
  write(name, K(arena.CurrentBytes):4,
    'B/', K(arena.CumulativeBytes), 'B ');
  {$ifdef FPCMM_DEBUG}
  write('   peak=', K(arena.PeakBytes),
    'B current=', K(arena.CumulativeAlloc - arena.CumulativeFree),
    ' alloc=', K(arena.CumulativeAlloc), ' free=', K(arena.CumulativeFree));
  {$endif FPCMM_DEBUG}
  writeln(' sleep=', K(arena.SleepCount) {$ifdef FPCMM_BOOST} , ' boost=on' {$endif});
end;

procedure WriteHeapStatus(const context: shortstring;
  smallblockstatuscount, smallblockcontentioncount: integer);
var
  status: TSmallBlockStatusDynArray;
  contention: TSmallBlockContentionDynArray;
  i, smallcount: PtrInt;
begin
  if context[0] <> #0 then
    writeln(context);
  with CurrentHeapStatus do
  begin
    writeln(' Small:  blocks=', K(SmallBlocks), ' size=', K(SmallBlocksSize),
      'B (as part of the Medium arena)');
    WriteHeapStatusDetail(Medium, ' Medium: ');
    WriteHeapStatusDetail(Large,  ' Large:  ');
    if SleepCount <> 0 then
      write(' Sleep:    count=', K(SleepCount)
        {$ifdef FPCMM_DEBUG} , ' microsec=', K(SleepTime) {$endif});
    smallcount := SmallGetmemSleepCount + SmallFreememSleepCount;
    if smallcount <> 0 then
      write(' getmem=', K(SmallGetmemSleepCount), ' freemem=', K(SmallFreememSleepCount));
  end;
  if (smallblockcontentioncount > 0) and (smallcount <> 0) then
  begin
    writeln;
    contention := GetSmallBlockContention;
    for i := 0 to high(contention) do
      with contention[i] do
      begin
        if GetmemBlockSize <> 0 then
          write(' getmem(', GetmemBlockSize)
        else
          write(' freemem(', FreememBlockSize);
        write(')=' , K(SleepCount));
        if i = smallblockcontentioncount then
          exit;
      end;
  end;
  if smallblockstatuscount > 0 then
  begin
   writeln;
   writeln(' Small Blocks by total use:');
   status := GetSmallBlockStatus(smallblockstatuscount, obTotal);
   for i := 0 to high(status) do
     with status[i] do
       write(' ', BlockSize, '=', K(Total));
   writeln;
   writeln(' Small Blocks by current use:');
   status := GetSmallBlockStatus(smallblockstatuscount, obCurrent);
   for i := 0 to high(status) do
     with status[i] do
       write(' ', BlockSize, '=', K(Current));
   writeln;
  end;
  writeln;
end;

{$I+}

type
  // match both TSmallBlockStatus and TSmallBlockContention
  TRes = array[0..2] of cardinal;
  TResArray = array[0..(NumSmallInfoBlock * 2) - 1] of TRes;

procedure QuickSortRes(var Res: TResArray; L, R, Level: PtrInt);
var
  I, J, P: PtrInt;
  pivot: cardinal;
  tmp: TRes;
begin
  if L < R then
    repeat
      I := L;
      J := R;
      P := (L + R) shr 1;
      repeat
        pivot := Res[P, Level];
        while Res[I, Level] > pivot do
          inc(I);
        while Res[J, Level] < pivot do
          dec(J);
        if I <= J then
        begin
          tmp := Res[J];
          Res[J] := Res[I];
          Res[I] := tmp;
          if P = I then
            P := J
          else if P = J then
            P := I;
          inc(I);
          dec(J);
        end;
      until I > J;
      if J - L < R - I then
      begin // use recursion only for smaller range
        if L < J then
          QuickSortRes(Res, L, J, Level);
        L := I;
      end
      else
      begin
        if I < R then
          QuickSortRes(Res, I, R, Level);
        R := J;
      end;
    until L >= R;
end;

function GetSmallBlockStatus(maxcount: integer;
  orderby: TSmallBlockOrderBy): TSmallBlockStatusDynArray;
var
  i, a: integer;
  p: PSmallBlockType;
  d: ^TSmallBlockStatus;
  res: TResArray;
begin
  assert(SizeOf(TRes) = SizeOf(TSmallBlockStatus));
  result := nil;
  if maxcount <= 0 then
    exit;
  d := @res;
  p := @SmallBlockInfo;
  for i := 1 to NumSmallBlockTypes do
  begin
    d^.Total := p^.GetmemCount;
    d^.Current := p^.GetmemCount - p^.FreememCount;
    d^.BlockSize := p^.BlockSize;
    inc(d);
    inc(p);
  end;
  for a := 1 to NumTinyBlockArenas do
  begin
    d := @res; // aggregate counters
    for i := 1 to NumTinyBlockTypes do
    begin
      inc(d^.Total, p^.GetmemCount);
      inc(d^.Current, p^.GetmemCount - p^.FreememCount);
      inc(d);
      inc(p);
    end;
  end;
  assert(p = @SmallBlockInfo.GetmemLookup);
  QuickSortRes(res, 0, NumSmallBlockTypes - 1, ord(orderby));
  if maxcount > NumSmallBlockTypes then
    maxcount := NumSmallBlockTypes;
  while (maxcount > 0) and (res[maxcount - 1, ord(orderby)] = 0) do
    dec(maxcount);
  if maxcount = 0 then
    exit;
  SetLength(result, maxcount);
  Move(res[0], result[0], maxcount * SizeOf(res[0]));
end;

function GetSmallBlockContention(maxcount: integer): TSmallBlockContentionDynArray;
var
  i, n: integer;
  p: PSmallBlockType;
  d: ^TSmallBlockContention;
  res: TResArray;
begin
  assert(SizeOf(TRes) = SizeOf(TSmallBlockContention));
  result := nil;
  if maxcount <= 0 then
    exit;
  n := 0;
  d := @res;
  p := @SmallBlockInfo;
  for i := 1 to NumSmallInfoBlock do
  begin
    if p^.GetmemSleepCount <> 0 then
    begin
      d^.SleepCount := p^.GetmemSleepCount;
      d^.GetmemBlockSize := p^.BlockSize;
      d^.FreememBlockSize := 0;
      inc(d);
      inc(n);
    end;
    if p^.FreememSleepCount <> 0 then
    begin
      d^.SleepCount := p^.FreememSleepCount;
      d^.GetmemBlockSize := 0;
      d^.FreememBlockSize := p^.BlockSize;
      inc(d);
      inc(n);
    end;
    inc(p);
  end;
  if n = 0 then
    exit;
  QuickSortRes(res, 0, n - 1, 0);
  if n > maxcount then
    n := maxcount;
  SetLength(result, n);
  Move(res[0], result[0], n * SizeOf(res[0]));
end;

{$endif FPCMM_STANDALONE}

function CurrentHeapStatus: TMMStatus;
var
  i: integer;
  small: PtrUInt;
  p: PSmallBlockType;
begin
  result := HeapStatus;
  p := @SmallBlockInfo;
  for i := 1 to NumSmallInfoBlock do
  begin
    inc(result.SmallGetmemSleepCount,  p^.GetmemSleepCount);
    inc(result.SmallFreememSleepCount, p^.FreememSleepCount);
    small := p^.GetmemCount - p^.FreememCount;
    if small <> 0 then
    begin
      inc(result.SmallBlocks, small);
      inc(result.SmallBlocksSize, small * p^.BlockSize);
    end;
    inc(p);
  end;
end;


{ ********* Initialization and Finalization }

procedure InitializeMemoryManager;
var
  small: PSmallBlockType;
  a, i, min, poolsize, num, perpool, size, start, next: PtrInt;
  medium: PMediumFreeBlock;
begin
  small := @SmallBlockInfo;
  assert(SizeOf(small^) = 64); // as expected above asm - match CPU cache line
  for a := 0 to NumTinyBlockArenas do
    for i := 0 to NumSmallBlockTypes - 1 do
    begin
      if (i = NumTinyBlockTypes) and (a > 0) then
        break;
      size := SmallBlockSizes[i];
      assert(size and 15 = 0);
      small^.BlockSize := size;
      small^.PreviousPartiallyFreePool := pointer(small);
      small^.NextPartiallyFreePool := pointer(small);
      small^.MaxSequentialFeedBlockAddress := pointer(0);
      small^.NextSequentialFeedBlockAddress := pointer(1);
      min := ((size * MinimumSmallBlocksPerPool +
         (SmallBlockPoolHeaderSize + MediumBlockGranularity - 1 - MediumBlockSizeOffset))
         and -MediumBlockGranularity) + MediumBlockSizeOffset;
      if min < MinimumMediumBlockSize then
        min := MinimumMediumBlockSize;
      num := (min + (- MinimumMediumBlockSize +
        MediumBlockBinsPerGroup * MediumBlockGranularity div 2)) div
        (MediumBlockBinsPerGroup * MediumBlockGranularity);
      if num > 7 then
        num := 7;
      small^.AllowedGroupsForBlockPoolBitmap := Byte(Byte(-1) shl num);
      small^.MinimumBlockPoolSize := MinimumMediumBlockSize +
        num * (MediumBlockBinsPerGroup * MediumBlockGranularity);
      poolsize := ((size * TargetSmallBlocksPerPool +
        (SmallBlockPoolHeaderSize + MediumBlockGranularity - 1 - MediumBlockSizeOffset))
        and -MediumBlockGranularity) + MediumBlockSizeOffset;
      if poolsize < OptimalSmallBlockPoolSizeLowerLimit then
        poolsize := OptimalSmallBlockPoolSizeLowerLimit;
      if poolsize > OptimalSmallBlockPoolSizeUpperLimit then
        poolsize := OptimalSmallBlockPoolSizeUpperLimit;
      perpool := (poolsize - SmallBlockPoolHeaderSize) div size;
      small^.OptimalBlockPoolSize := ((perpool * size +
         (SmallBlockPoolHeaderSize + MediumBlockGranularity - 1 - MediumBlockSizeOffset))
          and -MediumBlockGranularity) + MediumBlockSizeOffset;
      inc(small);
    end;
  assert(small = @SmallBlockInfo.GetmemLookup);
  {$ifndef FPCMM_ASSUMEMULTITHREAD}
  SmallBlockInfo.IsMultiThreadPtr := @IsMultiThread;
  {$endif FPCMM_ASSUMEMULTITHREAD}
  start := 0;
  with SmallBlockInfo do
    for i := 0 to NumSmallBlockTypes - 1 do
    begin
      next := PtrUInt(SmallBlockSizes[i]) div SmallBlockGranularity;
      while start < next do
      begin
        GetmemLookup[start] := i;
        inc(start);
      end;
    end;
  with MediumBlockInfo do
  begin
    PoolsCircularList.PreviousMediumBlockPoolHeader := @PoolsCircularList;
    PoolsCircularList.NextMediumBlockPoolHeader := @PoolsCircularList;
    for i := 0 to MediumBlockBinCount -1 do
    begin
      medium := @Bins[i];
      medium.PreviousFreeBlock := medium;
      medium.NextFreeBlock := medium;
    end;
  end;
  LargeBlocksCircularList.PreviousLargeBlockHeader := @LargeBlocksCircularList;
  LargeBlocksCircularList.NextLargeBlockHeader := @LargeBlocksCircularList;
end;

{$I-}

{$ifdef FPCMM_REPORTMEMORYLEAKS}
var
  MemoryLeakReported: boolean;

procedure StartReport;
begin
  if MemoryLeakReported then
    exit;
  writeln;
  writeln('WARNING! THIS PROGRAM LEAKS MEMORY!');
  MemoryLeakReported := true;
end;

// experimental detection of object class - use at your own risk
{.$define FPCMM_REPORTMEMORYLEAKS_EXPERIMENTAL}

procedure MediumMemoryLeakReport(p: PMediumBlockPoolHeader);
var
  block: PByte;
  header, size: PtrUInt;
  {$ifdef FPCMM_REPORTMEMORYLEAKS_EXPERIMENTAL}
  first, last, vmt: PByte;
  small: PSmallBlockPoolHeader;
  {$endif FPCMM_REPORTMEMORYLEAKS_EXPERIMENTAL}
begin
  with MediumBlockInfo do
  if (SequentialFeedBytesLeft = 0) or (PtrUInt(LastSequentiallyFed) < PtrUInt(p)) or
     (PtrUInt(LastSequentiallyFed) > PtrUInt(p) + MediumBlockPoolSize) then
    block := Pointer(PByte(p) + MediumBlockPoolHeaderSize)
  else
    if SequentialFeedBytesLeft <> MediumBlockPoolSize - MediumBlockPoolHeaderSize then
      block := LastSequentiallyFed
    else
      exit;
  repeat
    header := PPtrUInt(block - BlockHeaderSize)^;
    size := header and DropMediumAndLargeFlagsMask;
    if size = 0 then
      exit;
    if header and IsFreeBlockFlag = 0 then
      if header and IsSmallBlockPoolInUseFlag <> 0 then
      begin
        {$ifdef FPCMM_REPORTMEMORYLEAKS_EXPERIMENTAL}
        if PSmallBlockPoolHeader(block).BlocksInUse > 0 then
        begin
          first := PByte(block) + SmallBlockPoolHeaderSize;
          with PSmallBlockPoolHeader(block).BlockType^ do
          if (CurrentSequentialFeedPool <> pointer(block)) or
             (PtrUInt(NextSequentialFeedBlockAddress) >
              PtrUInt(MaxSequentialFeedBlockAddress)) then
            last := PByte(block) + (PPtrUInt(PByte(block) - BlockHeaderSize)^
              and DropMediumAndLargeFlagsMask) - BlockSize
          else
            last := Pointer(PByte(NextSequentialFeedBlockAddress) - 1);
          while first <= last do
          begin
            if ((PPtrUInt(first - BlockHeaderSize)^ and IsFreeBlockFlag) = 0) and
               (PPointer(first)^ <> nil) then
            begin
              vmt := PPointer(first)^; // _FreeMem() would have made vmt=nil
              try // try to access a TObject VMT
                if (PPtrInt(vmt + vmtInstanceSize)^ > 0) and
                   (PPtrInt(vmt + vmtInstanceSize)^ <=
                    PSmallBlockPoolHeader(block).BlockType.BlockSize) and
                   (PPointer(vmt + vmtClassName)^ <> nil) then
                begin
                   StartReport;
                   writeln('  potential leak of ', TObject(first).ClassName, ' (',
                     PSmallBlockPoolHeader(block).BlockType.BlockSize, 'B)');
                end;
              except
              end;
            end;
            inc(first, PSmallBlockPoolHeader(block).BlockType.BlockSize);
          end;
        end;
        {$endif FPCMM_REPORTMEMORYLEAKS_EXPERIMENTAL}
      end
      else
      begin
        StartReport;
        writeln(' medium block leak of ', K(size), 'B');
      end;
    inc(block, size);
  until false;
end;

{$endif FPCMM_REPORTMEMORYLEAKS}

procedure FreeAllMemory;
var
  medium, nextmedium: PMediumBlockPoolHeader;
  bin: PMediumFreeBlock;
  large, nextlarge: PLargeBlockHeader;
  p: PSmallBlockType;
  i, size: PtrUInt;
begin
  p := @SmallBlockInfo;
  for i := 1 to NumSmallInfoBlock do
  begin
    p^.PreviousPartiallyFreePool := pointer(p);
    p^.NextPartiallyFreePool := pointer(p);
    p^.NextSequentialFeedBlockAddress := pointer(1);
    p^.MaxSequentialFeedBlockAddress := nil;
    {$ifdef FPCMM_REPORTMEMORYLEAKS}
    size := p^.GetmemCount - p^.FreememCount;
    if size <> 0 then
    begin
      StartReport;
      writeln(' small block leak x', size, ' of size=', p^.BlockSize,
        'B  (getmem=', p^.GetmemCount, ' freemem=', p^.FreememCount, ')');
    end;
    {$endif FPCMM_REPORTMEMORYLEAKS}
    inc(p);
  end;
  with MediumBlockInfo do
  begin
    medium := PoolsCircularList.NextMediumBlockPoolHeader;
    while medium <> @PoolsCircularList do
    begin
      {$ifdef FPCMM_REPORTMEMORYLEAKS}
      MediumMemoryLeakReport(medium);
      {$endif FPCMM_REPORTMEMORYLEAKS}
      nextmedium := medium.NextMediumBlockPoolHeader;
      FreeMedium(medium);
      medium := nextmedium;
    end;
    PoolsCircularList.PreviousMediumBlockPoolHeader := @PoolsCircularList;
    PoolsCircularList.NextMediumBlockPoolHeader := @PoolsCircularList;
    for i := 0 to MediumBlockBinCount - 1 do
    begin
      bin := @Bins[i];
      bin.PreviousFreeBlock := bin;
      bin.NextFreeBlock := bin;
    end;
    BinGroupBitmap := 0;
    SequentialFeedBytesLeft := 0;
    for i := 0 to MediumBlockBinGroupCount - 1 do
      BinBitmaps[i] := 0;
  end;
  large := LargeBlocksCircularList.NextLargeBlockHeader;
  while large <> @LargeBlocksCircularList do
  begin
    size := large.BlockSizeAndFlags and DropMediumAndLargeFlagsMask;
    {$ifdef FPCMM_REPORTMEMORYLEAKS}
    StartReport;
    writeln(' large block leak of ', K(size), 'B');
    {$endif FPCMM_REPORTMEMORYLEAKS}
    nextlarge := large.NextLargeBlockHeader;
    FreeLarge(large, size);
    large := nextlarge;
  end;
  LargeBlocksCircularList.PreviousLargeBlockHeader := @LargeBlocksCircularList;
  LargeBlocksCircularList.NextLargeBlockHeader := @LargeBlocksCircularList;
end;

{$I+}

{$ifndef FPCMM_STANDALONE}

const
  NewMM: TMemoryManager = (
    NeedLock: false;
    GetMem: @_Getmem;
    FreeMem: @_FreeMem;
    FreememSize: @_FreememSize;
    AllocMem: @_AllocMem;
    ReallocMem: @_ReAllocMem;
    MemSize: @_MemSize;
    InitThread: nil;
    DoneThread: nil;
    RelocateHeap: nil;
    GetHeapStatus: @_GetHeapStatus;
    GetFPCHeapStatus: @_GetFPCHeapStatus);

var
  OldMM: TMemoryManager;

initialization
  InitializeMemoryManager;
  GetMemoryManager(OldMM);
  SetMemoryManager(NewMM);

finalization
  SetMemoryManager(OldMM);
  FreeAllMemory;

{$endif FPCMM_STANDALONE}

{$endif FPC_CPUX64}

end.

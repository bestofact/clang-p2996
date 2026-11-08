<#
.SYNOPSIS
    Rebuilds the whole clang-p2996 toolchain from the current source checkout:
    clang + clangd -> compiler-rt builtins -> libunwind/libc++abi/libc++ -> config file -> smoke test.
    Pull the fork yourself first (git stash / git pull / git stash pop) if you want the latest.

    Paths are detected automatically where possible:
      -Src     the fork clone: the current folder, or the folder this script is in
      -Mingw   llvm-mingw: found through the clang on PATH
      -Prefix  install folder: read from an existing build; on a first build you must pass it
    Any of them can be passed explicitly to override detection.

.EXAMPLE
    .\build-p2996-toolchain.ps1                                   # run from inside the clone
    .\build-p2996-toolchain.ps1 -Src D:\dev\repo\clang-p2996      # run from anywhere
    .\build-p2996-toolchain.ps1 -Prefix D:\programs\clang-p2996   # first build
    .\build-p2996-toolchain.ps1 -Jobs 8                           # limit parallel jobs (low memory)
#>
param(
    [string]$Src,
    [string]$Prefix,
    [string]$Mingw,
    [int]$Jobs = 0
)

$ErrorActionPreference = "Stop"

# CMake prefers forward slashes; also drop trailing slashes.
function To-CMakePath($p) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
    return ($full -replace '\\', '/').TrimEnd('/')
}

# ---------------------------------------------------------------- detect: required tools
foreach ($tool in "cmake", "ninja", "git") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' was not found on PATH. Install it first (e.g. winget install Kitware.CMake Ninja-build.Ninja)."
    }
}

# ---------------------------------------------------------------- detect: source clone
function Test-Clone($dir) {
    return $dir -and (Test-Path "$dir/llvm/CMakeLists.txt") -and (Test-Path "$dir/libcxx") -and (Test-Path "$dir/compiler-rt")
}
if (-not $Src) {
    foreach ($candidate in (Get-Location).Path, $PSScriptRoot) {
        if (Test-Clone $candidate) { $Src = $candidate; break }
    }
    if (-not $Src) { throw "Couldn't find the clang-p2996 clone. Run this from inside it, or pass -Src <path>." }
}
if (-not (Test-Clone $Src)) { throw "'$Src' doesn't look like an llvm-project / clang-p2996 clone." }
$Src = To-CMakePath $Src

$BuildCompiler = "$Src/build"

# ---------------------------------------------------------------- detect: install prefix
if (-not $Prefix) {
    $cache = "$BuildCompiler/CMakeCache.txt"
    if (Test-Path $cache) {
        $line = Select-String -Path $cache -Pattern '^CMAKE_INSTALL_PREFIX:PATH=(.*)$' | Select-Object -First 1
        if ($line) { $Prefix = $line.Matches[0].Groups[1].Value }
    }
    if (-not $Prefix) { throw "No previous build found to read the install folder from. Pass -Prefix <path> on the first build." }
}
$Prefix = To-CMakePath $Prefix

# ---------------------------------------------------------------- detect: llvm-mingw
# Looks at every clang on PATH and picks the first one whose folder has llvm-mingw's
# layout (a MinGW sysroot + llvm-ar), skipping the p2996 install itself.
function Test-LlvmMingw($root) {
    return (Test-Path "$root/x86_64-w64-mingw32/include") -and (Test-Path "$root/bin/llvm-ar.exe") -and (Test-Path "$root/bin/clang.exe")
}
if (-not $Mingw) {
    foreach ($c in (Get-Command clang.exe -All -ErrorAction SilentlyContinue)) {
        $root = To-CMakePath (Split-Path (Split-Path $c.Source))
        if ($root -ieq $Prefix) { continue }
        if (Test-LlvmMingw $root) { $Mingw = $root; break }
    }
    if (-not $Mingw) { throw "Couldn't find llvm-mingw through the clang on PATH. Add its bin folder to PATH, or pass -Mingw <path>." }
}
$Mingw = To-CMakePath $Mingw
if (-not (Test-LlvmMingw $Mingw)) { throw "'$Mingw' doesn't look like an llvm-mingw installation." }

Write-Host "Source    : $Src"
Write-Host "Install to: $Prefix"
Write-Host "llvm-mingw: $Mingw"
$BuildBuiltins = "$Src/build-builtins"
$BuildRuntimes = "$Src/build-runtimes"

$Clang   = "$Prefix/bin/clang.exe"
$ClangXX = "$Prefix/bin/clang++.exe"
$Ar      = "$Mingw/bin/llvm-ar.exe"
$Ranlib  = "$Mingw/bin/llvm-ranlib.exe"
$Cfg     = "$Prefix/bin/x86_64-w64-windows-gnu.cfg"

$NinjaJobs = @()
if ($Jobs -gt 0) { $NinjaJobs = @("-j", "$Jobs") }

# ---------------------------------------------------------------- helpers
function Step($title) {
    Write-Host ""
    Write-Host "==> $title" -ForegroundColor Cyan
}

# Runs a native command and stops the script if it fails
# (Windows PowerShell does not stop on native-command failures by itself).
function Run {
    param([Parameter(ValueFromRemainingArguments = $true)] $cmd)
    $exe, $rest = $cmd
    & $exe @rest
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $($cmd -join ' ')" }
}

function Write-Cfg($lines) {
    # clang config files must not start with a BOM, so write plain UTF-8.
    [System.IO.File]::WriteAllLines($Cfg, $lines, (New-Object System.Text.UTF8Encoding $false))
}

$started = Get-Date

# ---------------------------------------------------------------- 1. libunwind fix
Step "Applying libunwind EXCEPTION_DISPOSITION fix (if still needed)"
$seh = "$Src/libunwind/src/Unwind-seh.cpp"
$text = [System.IO.File]::ReadAllText($seh)
$old = 'return 4 /* ExceptionExecuteHandler in mingw */;'
$new = 'return static_cast<EXCEPTION_DISPOSITION>(4) /* ExceptionExecuteHandler in mingw */;'
if ($text.Contains($old)) {
    [System.IO.File]::WriteAllText($seh, $text.Replace($old, $new))
    Write-Host "Patched."
} else {
    Write-Host "Not needed (already patched or fixed upstream)."
}

# ---------------------------------------------------------------- 2. clang + clangd
Step "Building clang + clangd (incremental)"
if (-not (Test-Path "$BuildCompiler/build.ninja")) {
    Run cmake -S "$Src/llvm" -B $BuildCompiler -G Ninja `
        -DCMAKE_BUILD_TYPE=Release `
        "-DCMAKE_C_COMPILER=$Mingw/bin/clang.exe" "-DCMAKE_CXX_COMPILER=$Mingw/bin/clang++.exe" `
        -DLLVM_ENABLE_LLD=ON `
        "-DCMAKE_EXE_LINKER_FLAGS=-static" `
        "-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra" `
        -DLLVM_TARGETS_TO_BUILD=X86 `
        -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-w64-windows-gnu `
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ `
        -DCLANG_DEFAULT_RTLIB=compiler-rt `
        -DCLANG_DEFAULT_UNWINDLIB=libunwind `
        -DCLANG_DEFAULT_LINKER=lld `
        -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF `
        -DLLVM_PARALLEL_LINK_JOBS=2 `
        "-DCMAKE_INSTALL_PREFIX=$Prefix"
}
Run ninja -C $BuildCompiler @NinjaJobs clang clangd
Run ninja -C $BuildCompiler install-clang install-clang-resource-headers install-clangd

# Point the new clang at llvm-mingw's sysroot while the runtimes are built.
# (libc++ lines are added at the end, once the new libc++ is installed.)
Write-Cfg @("--sysroot=$Mingw")

$ResourceDir = (& $Clang -print-resource-dir).Trim()
Write-Host "Resource dir: $ResourceDir"

# ---------------------------------------------------------------- 3. compiler-rt builtins
# Clean build every time: these must be compiled by the *new* clang,
# and ninja can't tell that the compiler itself changed.
Step "Building compiler-rt builtins"
if (Test-Path $BuildBuiltins) { Remove-Item -Recurse -Force $BuildBuiltins }
Run cmake -S "$Src/compiler-rt/lib/builtins" -B $BuildBuiltins -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    "-DCMAKE_INSTALL_PREFIX=$ResourceDir" `
    "-DCMAKE_C_COMPILER=$Clang" "-DCMAKE_CXX_COMPILER=$ClangXX" `
    -DCMAKE_C_COMPILER_TARGET=x86_64-w64-windows-gnu `
    -DCMAKE_SYSTEM_NAME=Windows `
    -DCMAKE_C_COMPILER_WORKS=1 `
    "-DCMAKE_AR=$Ar" "-DCMAKE_RANLIB=$Ranlib" `
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=TRUE `
    -DCOMPILER_RT_USE_BUILTINS_LIBRARY=TRUE `
    -DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=FALSE `
    "-DLLVM_CONFIG_PATH=" `
    "-DCMAKE_FIND_ROOT_PATH=$Mingw/x86_64-w64-mingw32" `
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY `
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
Run ninja -C $BuildBuiltins @NinjaJobs
Run ninja -C $BuildBuiltins install

# ---------------------------------------------------------------- 4. libunwind + libc++abi + libc++
Step "Building libunwind + libc++abi + libc++"
if (Test-Path $BuildRuntimes) { Remove-Item -Recurse -Force $BuildRuntimes }
# Remove old libc++ headers so files deleted upstream don't linger.
if (Test-Path "$Prefix/include/c++") { Remove-Item -Recurse -Force "$Prefix/include/c++" }
Run cmake -S "$Src/runtimes" -B $BuildRuntimes -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    "-DCMAKE_INSTALL_PREFIX=$Prefix" `
    "-DCMAKE_C_COMPILER=$Clang" "-DCMAKE_CXX_COMPILER=$ClangXX" `
    -DCMAKE_CXX_COMPILER_TARGET=x86_64-w64-windows-gnu `
    -DCMAKE_SYSTEM_NAME=Windows `
    -DCMAKE_C_COMPILER_WORKS=TRUE -DCMAKE_CXX_COMPILER_WORKS=TRUE `
    "-DCMAKE_AR=$Ar" "-DCMAKE_RANLIB=$Ranlib" `
    "-DLLVM_ENABLE_RUNTIMES=libunwind;libcxxabi;libcxx" `
    -DLIBUNWIND_USE_COMPILER_RT=TRUE -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON `
    -DLIBCXXABI_USE_COMPILER_RT=ON -DLIBCXXABI_USE_LLVM_UNWINDER=ON `
    -DLIBCXXABI_ENABLE_SHARED=OFF "-DLIBCXXABI_LIBDIR_SUFFIX=" `
    -DLIBCXX_USE_COMPILER_RT=ON -DLIBCXX_CXX_ABI=libcxxabi `
    -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_STATIC=ON -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=TRUE `
    "-DLIBCXX_LIBDIR_SUFFIX=" -DLIBCXX_INCLUDE_TESTS=FALSE -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=FALSE `
    -DLIBCXX_INSTALL_MODULES=ON "-DLIBCXX_INSTALL_MODULES_DIR=$Prefix/share/libc++/v1" `
    "-DCMAKE_C_FLAGS_INIT=-D__USE_MINGW_ANSI_STDIO=1" `
    "-DCMAKE_CXX_FLAGS_INIT=-D__USE_MINGW_ANSI_STDIO=1"
Run ninja -C $BuildRuntimes @NinjaJobs
Run ninja -C $BuildRuntimes install

# ---------------------------------------------------------------- 5. final config file
Step "Writing config file"
Write-Cfg @(
    "--sysroot=$Mingw",
    "-stdlib++-isystem $Prefix/include/c++/v1",
    "-L$Prefix/lib"
)
Get-Content $Cfg

# ---------------------------------------------------------------- 6. smoke test
Step "Smoke test"
$tmp = Join-Path $env:TEMP "p2996-smoke"
New-Item -ItemType Directory -Force $tmp | Out-Null
@'
#include <meta>
#include <print>
int main() { std::println("{}", std::meta::display_string_of(^^int)); }
'@ | Set-Content -Encoding ascii "$tmp/refl.cpp"
Run $ClangXX -std=c++26 -freflection-latest "$tmp/refl.cpp" -o "$tmp/refl.exe"
$out = (& "$tmp/refl.exe").Trim()
if ($out -ne "int") { throw "Smoke test printed '$out', expected 'int'" }

& $Clang --version | Select-Object -First 1
$elapsed = (Get-Date) - $started
Write-Host ""
Write-Host ("All good. Finished in {0:hh\:mm\:ss}." -f $elapsed) -ForegroundColor Green
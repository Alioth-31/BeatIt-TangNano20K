$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$classes = Join-Path $projectRoot 'app\build\core-tests'
New-Item -ItemType Directory -Force -Path $classes | Out-Null
$sources = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'app\src\main\java\cn\nano20k\synth\core') -Filter '*.java' | ForEach-Object FullName)
$sources += Join-Path $projectRoot 'tests\CoreTests.java'
$javac = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\javac.exe' } else { 'javac' }
$java = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { 'java' }
& $javac -encoding UTF-8 -d $classes $sources
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $java -ea -cp $classes CoreTests
exit $LASTEXITCODE

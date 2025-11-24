@echo off
setlocal

REM This script runs all .crisp test files located in the tests/ directory
REM using the crisp-compile executable. It runs each test multiple times
REM with different flags to simulate the CI environment.

REM Ensure the executable exists before we start.
if not exist "bin\crisp-compile.exe" (
    echo Error: Compiler executable not found at bin\crisp-compile.exe
    echo Please build the project first using 'sbcl --load build/build.lisp'.
    exit /b 1
)

echo =================================================
echo            Running Crisp E2E Tests
echo =================================================

REM Loop through all .crisp files in the tests directory.
for %%f in (tests\*.crisp) do (
    echo.
    echo --- Running test: %%f ---
    bin\crisp-compile.exe %%f
    if errorlevel 1 (
        echo [FAILED] Test failed: %%f
    ) else (
        echo [PASSED]
    )

    echo --- Running test: %%f --debug ---
    bin\crisp-compile.exe %%f --debug
    if errorlevel 1 (
        echo [FAILED] Test failed: %%f --debug
    ) else (
        echo [PASSED]
    )
)

echo.
echo All tests complete.
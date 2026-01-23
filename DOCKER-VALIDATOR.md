# Docker C Validator Setup

## Installation Steps

1. **Install Docker Desktop for Windows**
   - Download from: https://www.docker.com/products/docker-desktop/
   - Install `Docker Desktop for Windows - x86_64`
   - Follow installer (requires WSL2, which it will install automatically)
   - Restart when prompted

2. **Build the validator image**
   ```powershell
   cd C:\Users\cperk\Documents\crisp
   docker build -f Dockerfile.validator -t crisp-c-validator .
   ```

3. **Test it works**
   ```powershell
   docker run --rm crisp-c-validator gcc --version
   # Should output: gcc (Alpine X.X.X) ...
   ```

4. **Run the test suite**
   ```powershell
   sbcl --script .\tests\run-specs.lisp --filter=01-minimal-kernel.crisp
   ```

## How It Works

The validator now uses Docker to compile C code:
- Mounts your crisp directory into the container at `/workspace`
- Runs `gcc -fsyntax-only` inside the container
- Reports compilation errors back to Lisp

## Performance

- First run: ~1-2 seconds (container startup)
- Subsequent runs: ~0.5-1 second per file
- Full test suite (13 tests): ~10-15 seconds added overhead

// Copy of the new std.process that is currently stuck waiting on changes
// to druntime, and for review. Since I don't need the parts affected by
// the needed druntime changes, using it here should be ok.

// Written in the D programming language.

/** This is a proposal for a replacement for the $(D std._process) module.

    This is a summary of the functions in this module:
    $(UL $(LI
        $(LREF spawnProcess) spawns a new _process, optionally assigning it an
        arbitrary set of standard input, output, and error streams.
        The function returns immediately, leaving the child _process to execute
        in parallel with its parent.  All other functions in this module that
        spawn processes are built around $(LREF spawnProcess).)
    $(LI
        $(LREF wait) makes the parent _process wait for a child _process to
        terminate.  In general one should always do this, to avoid
        child _processes becoming "zombies" when the parent _process exits.
        Scope guards are perfect for this – see the $(LREF spawnProcess)
        documentation for examples.)
    $(LI
        $(LREF pipeProcess) and $(LREF pipeShell) also spawn a child _process
        which runs in parallel with its parent.  However, instead of taking
        arbitrary streams, they automatically create a set of
        pipes that allow the parent to communicate with the child
        through the child's standard input, output, and/or error streams.
        These functions correspond roughly to C's $(D popen) function.)
    $(LI
        $(LREF execute) and $(LREF shell) start a new _process and wait for it
        to complete before returning.  Additionally, they capture
        the _process' standard output and error streams and return
        the output of these as a string.
        These correspond roughly to C's $(D system) function.)
    )
    $(LREF shell) and $(LREF pipeShell) both run the given command
    through the user's default command interpreter.  On Windows, this is
    the $(I cmd.exe) program, on POSIX it is determined by the SHELL environment
    variable (defaulting to $(I /bin/sh) if it cannot be determined).  The
    command is specified as a single string which is sent directly to the
    shell.

    The other commands all have two forms, one where the program name
    and its arguments are specified in a single string parameter, separated
    by spaces, and one where the arguments are specified as an array of
    strings.  Use the latter whenever the program name or any of the arguments
    contain spaces.

    Unless a directory is specified in the program name, all functions will
    search for the executable in the directories specified in the PATH
    environment variable.

    Macros:
    WIKI=Phobos/StdProcess
*/
module process;


version(Posix)
{
    import core.stdc.errno;
    import core.stdc.string;
    import core.sys.posix.stdio;
    import core.sys.posix.unistd;
    import core.sys.posix.sys.wait;
}
version(Windows)
{
    import core.sys.windows.windows;
    import std.utf;
    import std.windows.syserror;
    import std.c.stdio;
    version(DigitalMars)
    {
        // this helps on Wine
        version = PIPE_USE_ALT_FDOPEN;
    }
}

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.path;
import std.stdio;
import std.string;
import std.typecons;

version(Posix)
{
    version(OSX)
    {
        // https://www.gnu.org/software/gnulib/manual/html_node/environ.html
        private extern(C) extern __gshared char*** _NSGetEnviron();
        // need to declare environ = *_NSGetEnviron() in static this()
    }
    else
    {
        // Made available by the C runtime:
        private extern(C) extern __gshared const char** environ;
    }
}
else version(Windows)
{
    // Use the same spawnProcess() implementations on both Windows
    // and POSIX, only the spawnProcessImpl() function has to be
    // different.
    LPVOID environ = null;

    // TODO: This should be in druntime!
    extern(Windows)
    {
        alias WCHAR* LPWCH;
        LPWCH GetEnvironmentStringsW();
        BOOL FreeEnvironmentStringsW(LPWCH lpszEnvironmentBlock);
        DWORD GetEnvironmentVariableW(LPCWSTR lpName, LPWSTR lpBuffer,
            DWORD nSize);
        BOOL SetEnvironmentVariableW(LPCWSTR lpName, LPCWSTR lpValue);
    }
}




/** A handle corresponding to a spawned process. */
final class Pid
{
    /** The ID number assigned to the process by the operating
        system.
    */
    @property int processID() const
    {
        enforce(_processID >= 0,
            "Pid doesn't correspond to a running process.");
        return _processID;
    }


    // See module-level wait() for documentation.
    version(Posix) int wait()
    {
        if (_processID == terminated) return _exitCode;

        int exitCode;
        while(true)
        {
            int status;
            auto check = waitpid(processID, &status, 0);
            enforce (check != -1  ||  errno != ECHILD,
                "Process does not exist or is not a child process.");

            if (WIFEXITED(status))
            {
                exitCode = WEXITSTATUS(status);
                break;
            }
            else if (WIFSIGNALED(status))
            {
                exitCode = -WTERMSIG(status);
                break;
            }
            // Process has stopped, but not terminated, so we continue waiting.
        }

        // Mark Pid as terminated, and cache and return exit code.
        _processID = terminated;
        _exitCode = exitCode;
        return exitCode;
    }
    else version(Windows)
    {
        int wait()
        {
            if (_processID == terminated) return _exitCode;

            if(_handle != INVALID_HANDLE_VALUE)
            {
                auto result = WaitForSingleObject(_handle, INFINITE);
                enforce(result == WAIT_OBJECT_0, "Wait failed");
                // the process has exited, get the return code
                enforce(GetExitCodeProcess(_handle, cast(LPDWORD)&_exitCode));
                CloseHandle(_handle);
                _handle = INVALID_HANDLE_VALUE;
                _processID = terminated;
            }
            return _exitCode;
        }

        ~this()
        {
            if(_handle != INVALID_HANDLE_VALUE)
            {
                CloseHandle(_handle);
                _handle = INVALID_HANDLE_VALUE;
            }
        }
    }


private:

    // Special values for _processID.
    enum invalid = -1, terminated = -2;

    // OS process ID number.  Only nonnegative IDs correspond to
    // running processes.
    int _processID = invalid;


    // Exit code cached by wait().  This is only expected to hold a
    // sensible value if _processID == terminated.
    int _exitCode;


    // Pids are only meant to be constructed inside this module, so
    // we make the constructor private.
    version(Windows)
    {
        HANDLE _handle;
        this(int pid, HANDLE handle)
        {
            _processID = pid;
            _handle = handle;
        }
    }
    else
    {
        this(int id)
        {
            _processID = id;
        }
    }
}




/** Spawns a new process.

    This function returns immediately, and the child process
    executes in parallel with its parent.

    Unless a directory is specified in the $(D _command) (or $(D name))
    parameter, this function will search the directories in the
    PATH environment variable for the program.  To run an executable in
    the current directory, use $(D "./$(I executable_name)").

    Params:
        command = A string containing the program name and
            its arguments, separated by spaces.  If the program
            name or any of the arguments contain spaces, use
            the third or fourth form of this function, where
            they are specified separately.

        environmentVars = The environment variables for the
            child process can be specified using this parameter.
            If it is omitted, the child process executes in the
            same environment as the parent process.

        stdin_ = The standard input stream of the child process.
            This can be any $(XREF stdio,File) that is opened for reading.
            By default the child process inherits the parent's input
            stream.

        stdout_ = The standard output stream of the child process.
            This can be any $(XREF stdio,File) that is opened for writing.
            By default the child process inherits the parent's output
            stream.

        stderr_ = The standard error stream of the child process.
            This can be any $(XREF stdio,File) that is opened for writing.
            By default the child process inherits the parent's error
            stream.

        config = Options controlling the behaviour of $(D spawnProcess).
            See the $(LREF Config) documentation for details.

        name = The name of the executable file.

        args = The _command line arguments to give to the program.
            (There is no need to specify the program name as the
            zeroth argument; this is done automatically.)

    Note:
    If you pass an $(XREF stdio,File) object that is $(I not) one of the standard
    input/output/error streams of the parent process, that stream
    will by default be closed in the parent process when this
    function returns.  See the $(LREF Config) documentation below for information
    about how to disable this behaviour.

    Examples:
    Open Firefox on the D homepage and wait for it to complete:
    ---
    auto pid = spawnProcess("firefox http://www.d-programming-language.org");
    wait(pid);
    ---
    Use the $(I ls) _command to retrieve a list of files:
    ---
    string[] files;
    auto p = pipe();

    auto pid = spawnProcess("ls", stdin, p.writeEnd);
    scope(exit) wait(pid);

    foreach (f; p.readEnd.byLine())  files ~= f.idup;
    ---
    Use the $(I ls -l) _command to get a list of files, pipe the output
    to $(I grep) and let it filter out all files except D source files,
    and write the output to the file $(I dfiles.txt):
    ---
    // Let's emulate the command "ls -l | grep \.d > dfiles.txt"
    auto p = pipe();
    auto file = File("dfiles.txt", "w");

    auto lsPid = spawnProcess("ls -l", stdin, p.writeEnd);
    scope(exit) wait(lsPid);

    auto grPid = spawnProcess("grep \\.d", p.readEnd, file);
    scope(exit) wait(grPid);
    ---
    Open a set of files in OpenOffice Writer, and make it print
    any error messages to the standard output stream.  Note that since
    the filenames contain spaces, we have to pass them in an array:
    ---
    spawnProcess("oowriter", ["my document.odt", "your document.odt"],
        stdin, stdout, stdout);
    ---
*/
Pid spawnProcess(string command,
    File stdin_ = std.stdio.stdin,
    File stdout_ = std.stdio.stdout,
    File stderr_ = std.stdio.stderr,
    Config config = Config.none)
{
    auto splitCmd = split(command);
    return spawnProcessImpl(splitCmd[0], splitCmd[1 .. $],
        environ,
        stdin_, stdout_, stderr_, config);
}


/// ditto
Pid spawnProcess(string command, string[string] environmentVars,
    File stdin_ = std.stdio.stdin,
    File stdout_ = std.stdio.stdout,
    File stderr_ = std.stdio.stderr,
    Config config = Config.none)
{
    auto splitCmd = split(command);
    return spawnProcessImpl(splitCmd[0], splitCmd[1 .. $],
        toEnvz(environmentVars),
        stdin_, stdout_, stderr_, config);
}


/// ditto
Pid spawnProcess(string name, const string[] args,
    File stdin_ = std.stdio.stdin,
    File stdout_ = std.stdio.stdout,
    File stderr_ = std.stdio.stderr,
    Config config = Config.none)
{
    return spawnProcessImpl(name, args,
        environ,
        stdin_, stdout_, stderr_, config);
}


/// ditto
Pid spawnProcess(string name, const string[] args,
    string[string] environmentVars,
    File stdin_ = std.stdio.stdin,
    File stdout_ = std.stdio.stdout,
    File stderr_ = std.stdio.stderr,
    Config config = Config.none)
{
    return spawnProcessImpl(name, args,
        toEnvz(environmentVars),
        stdin_, stdout_, stderr_, config);
}


// The actual implementation of the above.
version(Posix) private Pid spawnProcessImpl
    (string name, const string[] args, const char** envz,
    File stdin_, File stdout_, File stderr_, Config config)
{
    string fullName = name;

    // Make sure the file exists and is executable.
    if (any!isDirSeparator(name))
    {
        enforce(isExecutable(fullName), "Not an executable file: "~name);
    }
    else
    {
        fullName = searchPathFor(name);
        enforce(fullName != null, "Executable file not found: "~name);
    }

    // Get the file descriptors of the streams.
    auto stdinFD  = core.stdc.stdio.fileno(stdin_.getFP());
    errnoEnforce(stdinFD != -1, "Invalid stdin stream");
    auto stdoutFD = core.stdc.stdio.fileno(stdout_.getFP());
    errnoEnforce(stdoutFD != -1, "Invalid stdout stream");
    auto stderrFD = core.stdc.stdio.fileno(stderr_.getFP());
    errnoEnforce(stderrFD != -1, "Invalid stderr stream");

    auto argz  = toArgz(fullName, args);
    auto namez = toStringz(fullName);

    auto id = fork();
    errnoEnforce (id >= 0, "Cannot spawn new process");

    if (id == 0)
    {
        // Child process

        // Redirect streams and close the old file descriptors.
        // In the case that stderr is redirected to stdout, we need
        // to backup the file descriptor since stdout may be redirected
        // as well.
        if (stderrFD == STDOUT_FILENO)  stderrFD = dup(stderrFD);
        dup2(stdinFD,  STDIN_FILENO);
        dup2(stdoutFD, STDOUT_FILENO);
        dup2(stderrFD, STDERR_FILENO);

        // Close the old file descriptors, unless they are
        // either of the standard streams.
        if (stdinFD  > STDERR_FILENO)  close(stdinFD);
        if (stdoutFD > STDERR_FILENO)  close(stdoutFD);
        if (stderrFD > STDERR_FILENO)  close(stderrFD);

        // Execute program
        execve(namez, argz, envz);

        // If execution fails, exit as quick as possible.
        perror("spawnProcess(): Failed to execute program");
        _exit(1);
        assert (0);
    }
    else
    {
        // Parent process:  Close streams and return.

        with (Config)
        {
            if (stdinFD  > STDERR_FILENO && !(config & noCloseStdin))
                stdin_.close();
            if (stdoutFD > STDERR_FILENO && !(config & noCloseStdout))
                stdout_.close();
            if (stderrFD > STDERR_FILENO && !(config & noCloseStderr))
                stderr_.close();
        }

        return new Pid(id);
    }
}
else version(Windows) private Pid spawnProcessImpl
    (string name, const string[] args, LPVOID envz,
    File stdin_, File stdout_, File stderr_, Config config)
{
    // Create a process info structure.  Note that we don't care about wide
    // characters yet.
    STARTUPINFO startinfo;
    startinfo.cb = startinfo.sizeof;

    // Create a process information structure.
    PROCESS_INFORMATION pi;

    //
    // Windows is a little strange when passing command line.  It requires the
    // command-line to be one single command line, and the quoting processing
    // is rather bizzare.  Through trial and error, here are the rules I've
    // discovered that Windows uses to parse the command line WRT quotes:
    //
    // inside or outside quote mode:
    // 1. if 2 or more backslashes are followed by a quote, the first
    //    2 backslashes are reduced to 1 backslash which does not
    //    affect anything after it.
    // 2. one backslash followed by a quote is interpreted as a
    //    literal quote, which cannot be used to close quote mode, and
    //    does not affect anything after it.
    //
    // outside quote mode:
    // 3. a quote enters quote mode
    // 4. whitespace delineates an argument
    //
    // inside quote mode:
    // 5. 2 quotes sequentially are interpreted as a literal quote and
    //    an exit from quote mode.
    // 6. a quote at the end of the string, or one that is followed by
    //    anything other than a quote exits quote mode, but does not
    //    affect the character after the quote.
    // 7. end of line exits quote mode
    //
    // In our 'reverse' routine, we will only utilize the first 2 rules
    // for escapes.
    //
    char[] cmdline;
    uint minsize = 0;
    foreach(s; args)
        minsize += args.length;

    // reserve enough space to hold the program and all the arguments, plus 3
    // extra characters per arg for the quotes and the space, plus 5 extra
    // chars for good measure (in case we have to add escaped quotes).
    cmdline.reserve(minsize + name.length + 3 * args.length + 5);

    // this could be written more optimized...
    void addArg(string a)
    {
        if(cmdline.length)
            cmdline ~= " ";
        // first, determine if we need a quote
        bool needquote = false;
        foreach(dchar d; a)
            if(d == ' ')
            {
                needquote = true;
                break;
            }
        if(needquote)
            cmdline ~= '"';
        foreach(dchar d; a)
        {
            if(d == '"')
                cmdline ~= '\\';
            cmdline ~= d;
        }
        if(needquote)
            cmdline ~= '"';
    }

    addArg(name);
    foreach(a; args)
        addArg(a);

    cmdline ~= '\0';

    // ok, the command line is ready.  Figure out the startup info
    startinfo.dwFlags = STARTF_USESTDHANDLES;
    // Get the file descriptors of the streams.
    auto stdinFD  = _fileno(stdin_.getFP());
    errnoEnforce(stdinFD != -1, "Invalid stdin stream");
    auto stdoutFD = _fileno(stdout_.getFP());
    errnoEnforce(stdoutFD != -1, "Invalid stdout stream");
    auto stderrFD = _fileno(stderr_.getFP());
    errnoEnforce(stderrFD != -1, "Invalid stderr stream");

    // need to convert file descriptors to HANDLEs
    startinfo.hStdInput = _fdToHandle(stdinFD);
    startinfo.hStdOutput = _fdToHandle(stdoutFD);
    startinfo.hStdError = _fdToHandle(stderrFD);

    // TODO: need to fix this for unicode
    if(!CreateProcessA(null, cmdline.ptr, null, null, true, (config & Config.gui) ? CREATE_NO_WINDOW : 0, envz, null, &startinfo, &pi))
    {
        throw new Exception("Error starting process: " ~ sysErrorString(GetLastError()), __FILE__, __LINE__);
    }

    // figure out if we should close any of the streams
    with (Config)
    {
        if (stdinFD  > STDERR_FILENO && !(config & noCloseStdin))
            stdin_.close();
        if (stdoutFD > STDERR_FILENO && !(config & noCloseStdout))
            stdout_.close();
        if (stderrFD > STDERR_FILENO && !(config & noCloseStderr))
            stderr_.close();
    }

    // close the thread handle in the process info structure
    CloseHandle(pi.hThread);

    return new Pid(pi.dwProcessId, pi.hProcess);
}

// Searches the PATH variable for the given executable file,
// (checking that it is in fact executable).
version(Posix) private string searchPathFor(string executable)
{
    auto pathz = environment["PATH"];
    if (pathz == null)  return null;

    foreach (dir; splitter(to!string(pathz), ':'))
    {
        auto execPath = buildPath(dir, executable);
        if (isExecutable(execPath))  return execPath;
    }

    return null;
}

// Converts a C array of C strings to a string[] array,
// setting the program name as the zeroth element.
version(Posix) private const(char)** toArgz(string prog, const string[] args)
{
    alias const(char)* stringz_t;
    auto argz = new stringz_t[](args.length+2);

    argz[0] = toStringz(prog);
    foreach (i; 0 .. args.length)
    {
        argz[i+1] = toStringz(args[i]);
    }
    argz[$-1] = null;
    return argz.ptr;
}

// Converts a string[string] array to a C array of C strings
// on the form "key=value".
version(Posix) private const(char)** toEnvz(const string[string] env)
{
    alias const(char)* stringz_t;
    auto envz = new stringz_t[](env.length+1);
    int i = 0;
    foreach (k, v; env)
    {
        envz[i] = (k~'='~v~'\0').ptr;
        i++;
    }
    envz[$-1] = null;
    return envz.ptr;
}
else version(Windows) private LPVOID toEnvz(const string[string] env)
{
    uint len = 1; // reserve 1 byte for termination of environment block
    foreach(k, v; env)
    {
        len += k.length + v.length + 2; // one for '=', one for null char
    }

    char [] envz;
    envz.reserve(len);
    foreach(k, v; env)
    {
        envz ~= k ~ '=' ~ v ~ '\0';
    }

    envz ~= '\0';
    return envz.ptr;
}


// Checks whether the file exists and can be executed by the
// current user.
version(Posix) private bool isExecutable(string path)
{
    return (access(toStringz(path), X_OK) == 0);
}




/** Flags that control the behaviour of $(LREF spawnProcess).
    Use bitwise OR to combine flags.

    Example:
    ---
    auto logFile = File("myapp_error.log", "w");

    // Start program in a console window (Windows only), redirect
    // its error stream to logFile, and leave logFile open in the
    // parent process as well.
    auto pid = spawnProcess("myapp", stdin, stdout, logFile,
        Config.noCloseStderr | Config.gui);
    scope(exit)
    {
        auto exitCode = wait(pid);
        logFile.writeln("myapp exited with code ", exitCode);
        logFile.close();
    }
    ---
*/
enum Config
{
    none = 0,

    /** Unless the child process inherits the standard
        input/output/error streams of its parent, one almost
        always wants the streams closed in the parent when
        $(LREF spawnProcess) returns.  Therefore, by default, this
        is done.  If this is not desirable, pass any of these
        options to spawnProcess.
    */
    noCloseStdin  = 1,
    noCloseStdout = 2,                                  /// ditto
    noCloseStderr = 4,                                  /// ditto

    /** On Windows, this option causes the process to run in
        a console window.  On POSIX it has no effect.
    */
    gui = 8,
}




/** Waits for a specific spawned process to terminate and returns
    its exit status.

    In general one should always _wait for child processes to terminate
    before exiting the parent process.  Otherwise, they may become
    "$(WEB en.wikipedia.org/wiki/Zombie_process,zombies)" – processes
    that are defunct, yet still occupy a slot in the OS process table.

    Note:
    On POSIX systems, if the process is terminated by a signal,
    this function returns a negative number whose absolute value
    is the signal number.  (POSIX restricts normal exit codes
    to the range 0-255.)

    Examples:
    See the $(LREF spawnProcess) documentation.
*/
int wait(Pid pid)
{
    enforce(pid !is null, "Called wait on a null Pid.");
    return pid.wait();
}



/+
/** Creates a unidirectional _pipe.

    Data is written to one end of the _pipe and read from the other.
    ---
    auto p = pipe();
    p.writeEnd.writeln("Hello World");
    assert (p.readEnd.readln().chomp() == "Hello World");
    ---
    Pipes can, for example, be used for interprocess communication
    by spawning a new process and passing one end of the _pipe to
    the child, while the parent uses the other end.  See the
    $(LREF spawnProcess) documentation for examples of this.
*/
version(Posix) Pipe pipe()
{
    int[2] fds;
    errnoEnforce(core.sys.posix.unistd.pipe(fds) == 0,
                 "Unable to create pipe");

    Pipe p;

    // TODO: Using the internals of File like this feels like a hack,
    // but the File.wrapFile() function disables automatic closing of
    // the file.  Perhaps there should be a protected version of
    // wrapFile() that fills this purpose?
    p._read.p = new File.Impl(
        errnoEnforce(fdopen(fds[0], "r"), "Cannot open read end of pipe"),
        1, null);
    p._write.p = new File.Impl(
        errnoEnforce(fdopen(fds[1], "w"), "Cannot open write end of pipe"),
        1, null);

    return p;
}
else version(Windows) Pipe pipe()
{
    // use CreatePipe to create an anonymous pipe
    HANDLE readHandle;
    HANDLE writeHandle;
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sa.sizeof;
    sa.lpSecurityDescriptor = null;
    sa.bInheritHandle = true;
    if(!CreatePipe(&readHandle, &writeHandle, &sa, 0))
    {
        throw new Exception("Error creating pipe: " ~ sysErrorString(GetLastError()), __FILE__, __LINE__);
    }

    // Create file descriptors from the handles
    auto readfd = _handleToFD(readHandle, FHND_DEVICE);
    auto writefd = _handleToFD(writeHandle, FHND_DEVICE);

    Pipe p;
    version(PIPE_USE_ALT_FDOPEN)
    {
        // This is a re-implementation of DMC's fdopen, but without the
        // mucking with the file descriptor.  POSIX standard requires the
        // new fdopen'd file to retain the given file descriptor's
        // position.
        FILE * local_fdopen(int fd, const(char)* mode)
        {
            auto fp = core.stdc.stdio.fopen("NUL", mode);
            if(!fp)
                return null;
            FLOCK(fp);
            auto iob = cast(_iobuf*)fp;
            .close(iob._file);
            iob._file = fd;
            iob._flag &= ~_IOTRAN;
            FUNLOCK(fp);
            return fp;
        }

        p._read.p = new File.Impl(
            errnoEnforce(local_fdopen(readfd, "r"), "Cannot open read end of pipe"),
            1, null);
        p._write.p = new File.Impl(
            errnoEnforce(local_fdopen(writefd, "a"), "Cannot open write end of pipe"),
            1, null);
    }
    else
    {
        p._read.p = new File.Impl(
            errnoEnforce(fdopen(readfd, "r"), "Cannot open read end of pipe"),
            1, null);
        p._write.p = new File.Impl(
            errnoEnforce(fdopen(writefd, "a"), "Cannot open write end of pipe"),
            1, null);
    }

    return p;
}


/// ditto
struct Pipe
{
    /** The read end of the pipe. */
    @property File readEnd() { return _read; }


    /** The write end of the pipe. */
    @property File writeEnd() { return _write; }


    /** Closes both ends of the pipe.

        Normally it is not necessary to do this manually, as $(XREF stdio,File)
        objects are automatically closed when there are no more references
        to them.

        Note that if either end of the pipe has been passed to a child process,
        it will only be closed in the parent process.
    */
    void close()
    {
        _read.close();
        _write.close();
    }


private:
    File _read, _write;
}


unittest
{
    auto p = pipe();
    p.writeEnd.writeln("Hello World");
    assert (p.readEnd.readln().chomp() == "Hello World");
}




// ============================== pipeProcess() ==============================


/** Starts a new process, creating pipes to redirect its standard
    input, output and/or error streams.

    These functions return immediately, leaving the child process to
    execute in parallel with the parent.
    $(LREF pipeShell) invokes the user's _command interpreter
    to execute the given program or _command.

    Example:
    ---
    auto pipes = pipeProcess("my_application");

    // Store lines of output.
    string[] output;
    foreach (line; pipes.stdout.byLine) output ~= line.idup;

    // Store lines of errors.
    string[] errors;
    foreach (line; pipes.stderr.byLine) errors ~= line.idup;
    ---
*/
ProcessPipes pipeProcess(string command,
    Redirect redirectFlags = Redirect.all)
{
    auto splitCmd = split(command);
    return pipeProcess(splitCmd[0], splitCmd[1 .. $], redirectFlags);
}


/// ditto
ProcessPipes pipeProcess(string name, string[] args,
    Redirect redirectFlags = Redirect.all)
{
    File stdinFile, stdoutFile, stderrFile;

    ProcessPipes pipes;
    pipes._redirectFlags = redirectFlags;

    if (redirectFlags & Redirect.stdin)
    {
        auto p = pipe();
        stdinFile = p.readEnd;
        pipes._stdin = p.writeEnd;
    }
    else
    {
        stdinFile = std.stdio.stdin;
    }

    if (redirectFlags & Redirect.stdout)
    {
        enforce((redirectFlags & Redirect.stdoutToStderr) == 0,
            "Invalid combination of options: Redirect.stdout | "
           ~"Redirect.stdoutToStderr");
        auto p = pipe();
        stdoutFile = p.writeEnd;
        pipes._stdout = p.readEnd;
    }
    else
    {
        stdoutFile = std.stdio.stdout;
    }

    if (redirectFlags & Redirect.stderr)
    {
        enforce((redirectFlags & Redirect.stderrToStdout) == 0,
            "Invalid combination of options: Redirect.stderr | "
           ~"Redirect.stderrToStdout");
        auto p = pipe();
        stderrFile = p.writeEnd;
        pipes._stderr = p.readEnd;
    }
    else
    {
        stderrFile = std.stdio.stderr;
    }

    if (redirectFlags & Redirect.stdoutToStderr)
    {
        if (redirectFlags & Redirect.stderrToStdout)
        {
            // We know that neither of the other options have been
            // set, so we assign the std.stdio.std* streams directly.
            stdoutFile = std.stdio.stderr;
            stderrFile = std.stdio.stdout;
        }
        else
        {
            stdoutFile = stderrFile;
        }
    }
    else if (redirectFlags & Redirect.stderrToStdout)
    {
        stderrFile = stdoutFile;
    }

    pipes._pid = spawnProcess(name, args, stdinFile, stdoutFile, stderrFile);
    return pipes;
}


/// ditto
ProcessPipes pipeShell(string command, Redirect redirectFlags = Redirect.all)
{
    return pipeProcess(getShell(), [shellSwitch, command], redirectFlags);
}




/** Flags that can be passed to $(LREF pipeProcess) and $(LREF pipeShell)
    to specify which of the child process' standard streams are redirected.
    Use bitwise OR to combine flags.
*/
enum Redirect
{
    none = 0,

    /** Redirect the standard input, output or error streams, respectively. */
    stdin = 1,
    stdout = 2,                             /// ditto
    stderr = 4,                             /// ditto
    all = stdin | stdout | stderr,          /// ditto

    /** Redirect the standard error stream into the standard output
        stream, and vice versa.
    */
    stderrToStdout = 8,
    stdoutToStderr = 16,                    /// ditto
}




/** Object containing $(XREF stdio,File) handles that allow communication with
    a child process through its standard streams.
*/
struct ProcessPipes
{
    /** Returns the $(LREF Pid) of the child process. */
    @property Pid pid()
    {
        enforce (_pid !is null);
        return _pid;
    }


    /** Returns an $(XREF stdio,File) that allows writing to the child process'
        standard input stream.
    */
    @property File stdin()
    {
        enforce ((_redirectFlags & Redirect.stdin) > 0,
            "Child process' standard input stream hasn't been redirected.");
        return _stdin;
    }


    /** Returns an $(XREF stdio,File) that allows reading from the child
        process' standard output/error stream.
    */
    @property File stdout()
    {
        enforce ((_redirectFlags & Redirect.stdout) > 0,
            "Child process' standard output stream hasn't been redirected.");
        return _stdout;
    }

    /// ditto
    @property File stderr()
    {
        enforce ((_redirectFlags & Redirect.stderr) > 0,
            "Child process' standard error stream hasn't been redirected.");
        return _stderr;
    }


private:

    Redirect _redirectFlags;
    Pid _pid;
    File _stdin, _stdout, _stderr;
}




// ============================== execute() ==============================


/** Executes the given program and returns its exit code and output.

    This function blocks until the program terminates.
    The $(D output) string includes what the program writes to its
    standard error stream as well as its standard output stream.
    ---
    auto dmd = execute("dmd myapp.d");
    if (dmd.status != 0) writeln("Compilation failed:\n", dmd.output);
    ---
*/
Tuple!(int, "status", string, "output") execute(string command)
{
    auto p = pipeProcess(command,
        Redirect.stdout | Redirect.stderrToStdout);

    Appender!(ubyte[]) a;
    foreach (ubyte[] chunk; p.stdout.byChunk(4096))  a.put(chunk);

    typeof(return) r;
    r.output = cast(string) a.data;
    r.status = wait(p.pid);
    return r;
}


/// ditto
Tuple!(int, "status", string, "output") execute(string name, string[] args...)
{
    auto p = pipeProcess(name, args,
        Redirect.stdout | Redirect.stderrToStdout);

    Appender!(ubyte[]) a;
    foreach (ubyte[] chunk; p.stdout.byChunk(4096))  a.put(chunk);

    typeof(return) r;
    r.output = cast(string) a.data;
    r.status = wait(p.pid);
    return r;
}




// ============================== shell() ==============================


version(Posix)   private immutable string shellSwitch = "-c";
version(Windows) private immutable string shellSwitch = "/C";


// Gets the user's default shell.
version(Posix)  private string getShell()
{
    return environment.get("SHELL", "/bin/sh");
}

version(Windows) private string getShell()
{
    return "cmd.exe";
}




/** Executes $(D _command) in the user's default _shell and returns its
    exit code and output.

    This function blocks until the command terminates.
    The $(D output) string includes what the command writes to its
    standard error stream as well as its standard output stream.
    ---
    auto ls = shell("ls -l");
    writefln("ls exited with code %s and said: %s", ls.status, ls.output);
    ---
*/
Tuple!(int, "status", string, "output") shell(string command)
{
    version(Windows)
        return execute(getShell() ~ " " ~ shellSwitch ~ " " ~ command);
    else version(Posix)
        return execute(getShell(), shellSwitch, command);
    else assert(0);
}
+/



// ============================== thisProcessID ==============================


/** Returns the process ID number of the current process. */
version(Posix) @property int thisProcessID()
{
    return getpid();
}

version(Windows) @property int thisProcessID()
{
    return GetCurrentProcessId();
}




// ============================== environment ==============================


/** Manipulates environment variables using an associative-array-like
    interface.

    Examples:
    ---
    // Return variable, or throw an exception if it doesn't exist.
    string path = environment["PATH"];

    // Add/replace variable.
    environment["foo"] = "bar";

    // Remove variable.
    environment.remove("foo");

    // Return variable, or null if it doesn't exist.
    string foo = environment.get("foo");

    // Return variable, or a default value if it doesn't exist.
    string foo = environment.get("foo", "default foo value");

    // Return an associative array containing all the environment variables.
    string[string] aa = environment.toAA();
    ---
*/
alias Environment environment;

abstract final class Environment
{
    // initiaizes the value of environ for OSX
    version(OSX)
    {
        static private char** environ;
        static this()
        {
            environ = * _NSGetEnviron();
        }
    }


static:

    // Retrieves an environment variable, throws on failure.
    string opIndex(string name)
    {
        string value;
        enforce(getImpl(name, value), "Environment variable not found: "~name);
        return value;
    }



    // Assigns a value to an environment variable.  If the variable
    // exists, it is overwritten.
    string opIndexAssign(string value, string name)
    {
        version(Posix)
        {
            if (core.sys.posix.stdlib.setenv(toStringz(name),
                toStringz(value), 1) != -1)
            {
                return value;
            }

            // The default errno error message is very uninformative
            // in the most common case, so we handle it manually.
            enforce(errno != EINVAL,
                "Invalid environment variable name: '"~name~"'");
            errnoEnforce(false,
                "Failed to add environment variable");
            assert(0);
        }

        else version(Windows)
        {
            enforce(
                SetEnvironmentVariableW(toUTF16z(name), toUTF16z(value)),
                sysErrorString(GetLastError())
            );
            return value;
        }

        else static assert(0);
    }



    // Removes an environment variable.  The function succeeds even
    // if the variable isn't in the environment.
    void remove(string name)
    {
        version(Posix)
        {
            core.sys.posix.stdlib.unsetenv(toStringz(name));
        }

        else version(Windows)
        {
            SetEnvironmentVariableW(toUTF16z(name), null);
        }

        else static assert(0);
    }



    // Same as opIndex, except it returns a default value if
    // the variable doesn't exist.
    string get(string name, string defaultValue = null)
    {
        string value;
        auto found = getImpl(name, value);
        return found ? value : defaultValue;
    }



    // Returns all environment variables in an associative array.
    string[string] toAA()
    {
        string[string] aa;

        version(Posix)
        {
            for (int i=0; environ[i] != null; ++i)
            {
                immutable varDef = to!string(environ[i]);
                immutable eq = std.string.indexOf(varDef, '=');
                assert (eq >= 0);

                immutable name = varDef[0 .. eq];
                immutable value = varDef[eq+1 .. $];

                // In POSIX, environment variables may be defined more
                // than once.  This is a security issue, which we avoid
                // by checking whether the key already exists in the array.
                // For more info:
                // http://www.dwheeler.com/secure-programs/Secure-Programs-HOWTO/environment-variables.html
                if (name !in aa)  aa[name] = value;
            }
        }

        else version(Windows)
        {
            auto envBlock = GetEnvironmentStringsW();
            enforce (envBlock, "Failed to retrieve environment variables.");
            scope(exit) FreeEnvironmentStringsW(envBlock);

            for (int i=0; envBlock[i] != '\0'; ++i)
            {
                auto start = i;
                while (envBlock[i] != '=')
                {
                    assert (envBlock[i] != '\0');
                    ++i;
                }
                immutable name = toUTF8(envBlock[start .. i]);

                start = i+1;
                while (envBlock[i] != '\0') ++i;
                aa[name] = toUTF8(envBlock[start .. i]);
            }
        }

        else static assert(0);

        return aa;
    }


private:

    // Returns the length of an environment variable (in number of
    // wchars, including the null terminator), or 0 if it doesn't exist.
    version(Windows)
    int varLength(LPCWSTR namez)
    {
        return GetEnvironmentVariableW(namez, null, 0);
    }


    // Retrieves the environment variable, returns false on failure.
    bool getImpl(string name, out string value)
    {
        version(Posix)
        {
            const vz = core.sys.posix.stdlib.getenv(toStringz(name));
            if (vz == null) return false;
            auto v = vz[0 .. strlen(vz)];

            // Cache the last call's result.
            static string lastResult;
            if (v != lastResult) lastResult = v.idup;
            value = lastResult;
            return true;
        }

        else version(Windows)
        {
            const namez = toUTF16z(name);
            immutable len = varLength(namez);
            if (len == 0) return false;
            if (len == 1) return true;

            auto buf = new WCHAR[len];
            GetEnvironmentVariableW(namez, buf.ptr, buf.length);
            value = toUTF8(buf[0 .. $-1]);
            return true;
        }

        else static assert(0);
    }
}


unittest
{
    // New variable
    environment["std_process"] = "foo";
    assert (environment["std_process"] == "foo");

    // Set variable again
    environment["std_process"] = "bar";
    assert (environment["std_process"] == "bar");

    // Remove variable
    environment.remove("std_process");

    // Remove again, should succeed
    environment.remove("std_process");

    // Throw on not found.
    try { environment["std_process"]; assert(0); } catch(Exception e) { }

    // get() without default value
    assert (environment.get("std.process") == null);

    // get() with default value
    assert (environment.get("std_process", "baz") == "baz");

    // Convert to associative array
    auto aa = environment.toAA();
    assert (aa.length > 0);
    foreach (n, v; aa)
    {
        // Wine has some bugs related to environment variables:
        //  - Wine allows the existence of an env. variable with the name
        //    "\0", but GetEnvironmentVariable refuses to retrieve it.
        //  - If an env. variable has zero length, i.e. is "\0",
        //    GetEnvironmentVariable should return 1.  Instead it returns
        //    0, indicating the variable doesn't exist.
        version(Windows)  if (n.length == 0 || v.length == 0) continue;

        assert (v == environment[n]);
    }
}

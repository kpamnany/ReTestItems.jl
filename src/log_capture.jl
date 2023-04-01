const LOG_DISPLAY_MODES = (:eager, :issues, :batched)

const DEFAULT_STDOUT = Ref{IO}()
const DEFAULT_STDERR = Ref{IO}()
const DEFAULT_LOGSTATE = Ref{Base.CoreLogging.LogState}()
const DEFAULT_LOGGER = Ref{Base.CoreLogging.AbstractLogger}()

function save_current_stdio()
    DEFAULT_STDERR[] = stderr
    DEFAULT_STDOUT[] = stdout
    DEFAULT_LOGSTATE[] = Base.CoreLogging._global_logstate
    DEFAULT_LOGGER[] = Base.CoreLogging._global_logstate.logger
end

function default_log_display_mode(report::Bool, nworkers::Integer, interactive::Bool=Base.isinteractive())
    @assert nworkers >= 0
    if interactive
        if report || nworkers > 1
            return :batched
        else
            return :eager
        end
    else
        return :issues
    end
end

# Adapted from Base.time_print
function time_print(io; elapsedtime, bytes=0, gctime=0, allocs=0, compile_time=0, recompile_time=0)
    print(io, Base.Ryu.writefixed(Float64(elapsedtime/1e9), 6), " seconds")
    parens = bytes != 0 || allocs != 0 || gctime > 0 || compile_time > 0
    parens && print(io, " (")
    if bytes != 0 || allocs != 0
        allocs, ma = Base.prettyprint_getunits(allocs, length(Base._cnt_units), Int64(1000))
        if ma == 1
            print(io, Int(allocs), Base._cnt_units[ma], allocs==1 ? " allocation: " : " allocations: ")
        else
            print(io, Base.Ryu.writefixed(Float64(allocs), 2), Base._cnt_units[ma], " allocations: ")
        end
        print(io, Base.format_bytes(bytes))
    end
    if gctime > 0
        if bytes != 0 || allocs != 0
            print(io, ", ")
        end
        print(io, Base.Ryu.writefixed(Float64(100*gctime/elapsedtime), 2), "% gc time")
    end
    if compile_time > 0
        if bytes != 0 || allocs != 0 || gctime > 0
            print(io, ", ")
        end
        print(io, Base.Ryu.writefixed(Float64(100*compile_time/elapsedtime), 2), "% compilation time")
    end
    if recompile_time > 0
        perc = Float64(100 * recompile_time / compile_time)
        # use "<1" to avoid the confusing UX of reporting 0% when it's >0%
        print(io, ": ", perc < 1 ? "<1" : Base.Ryu.writefixed(perc, 0), "% of which was recompilation")
    end
    parens && print(io, ")")
end

function logfile_name(ti::TestItem, i=nothing)
    # Replacing reserved chars https://en.wikipedia.org/wiki/Filename
    # File name should remain unique due to the inclusion of `ti.id`.
    safe_name = replace(ti.name, r"[/\\\?%\*\:\|\"\<\>\.\,\;\=\s\$\#\@]" => "_")
    i = something(i, length(ti.testsets) + 1)  # Separate log file for each retry.
    return string("ReTestItems_test_", first(safe_name, 150), "_", ti.id[], "_", i, ".log")
end
function logfile_name(ts::TestSetup)
    # Test setup names should be unique to begin with, but we add hash of their location to be sure
    string("ReTestItems_setup_", ts.name, "_", hash(ts.file, UInt(ts.line)), ".log")
end
logpath(ti::TestItem, i=nothing) = joinpath(RETESTITEMS_TEMP_FOLDER, logfile_name(ti, i))
logpath(ts::TestSetup) = joinpath(RETESTITEMS_TEMP_FOLDER, logfile_name(ts))

"""
    _redirect_logs(f, target::Union{IO,String})

Redirects stdout and stderr while `f` is evaluated to `target`.
If target is String it is assumed it is a file path.
"""
_redirect_logs(f, path::String) = open(io->_redirect_logs(f, io), path, "w")
function _redirect_logs(f, target::IO)
    target === DEFAULT_STDOUT[] && return f()
    colored_io = IOContext(target, :color => get(DEFAULT_STDOUT[], :color, false))
    redirect_stdio(f, stdout=colored_io, stderr=colored_io)
end

# A lock that helps to stagger prints to DEFAULT_STDOUT, e.g. when there are log messages
# comming from distributed workers, reports for stalled tests and outputs of
# `print_errors_and_captured_logs`.
const LogCaptureLock = ReentrantLock()
macro loglock(expr)
    return :(@lock LogCaptureLock $(esc(expr)))
end

# NOTE: stderr and stdout are not safe to use during precompilation time,
# specifically until `Base.init_stdio` has been called. This is why we store
# the e.g. DEFAULT_STDOUT reference during __init__.
_not_compiling() = ccall(:jl_generating_output, Cint, ()) == 0

### Logging and reporting helpers ##########################################################

_on_worker() = " on worker $(Libc.getpid())"
_on_worker(ti::TestItem) = " on worker $(ti.workerid[])"
_file_info(ti::Union{TestSetup,TestItem}) = string(relpath(ti.file, ti.project_root), ":", ti.line)
_has_logs(ts::TestSetup) = filesize(logpath(ts)) > 0
# The path might not exist if a testsetup always throws an error and we don't get to actually
# evaluate the test item.
_has_logs(ti::TestItem, i=nothing) = (path = logpath(ti, i); (isfile(path) && filesize(path) > 0))

"""
    print_errors_and_captured_logs(ti::TestItem, run_number::Int; logs=:batched)

When a testitem doesn't succeed, we print the corresponding error/failure reports
from the testset and any logs that we captured while the testitem was eval()'d.

For `:eager` mode of `logs` we don't print any logs as they bypass log capture. `:batched`
means we print logs even for passing test items, whereas `:issues` means we are only printing
captured logs if there were any errors or failures.

Nothing is printed when no logs were captures and no failures or errors occured.
"""
print_errors_and_captured_logs(ti::TestItem, run_number::Int; logs=:batched) =
    print_errors_and_captured_logs(DEFAULT_STDOUT[], ti, run_number; logs)
function print_errors_and_captured_logs(io, ti::TestItem, run_number::Int; logs=:batched)
    ts = ti.testsets[run_number]
    has_errors = ts.anynonpass
    has_logs = _has_logs(ti, run_number) || any(_has_logs, ti.testsetups)
    if has_errors || logs == :batched
        report_iob = IOContext(IOBuffer(), :color=>Base.get_have_color())
        println(report_iob)
        # in :eager mode, the logs were already printed
        logs != :eager && _print_captured_logs(report_iob, ti, run_number)
        has_errors && _print_test_errors(report_iob, ts, _on_worker(ti))
        if has_errors || has_logs
            # a newline to visually separate the report for the current test item
            println(report_iob)
            # Printing in one go to minimize chance of mixing with other concurrent prints
            @loglock write(io, take!(report_iob.io))
        end
    end
    # If we have errors, keep the tesitem log file for JUnit report.
    !has_errors && rm(logpath(ti, run_number), force=true)
    return nothing
end

function _print_captured_logs(io, setup::TestSetup, ti::Union{Nothing,TestItem}=nothing)
    if _has_logs(setup)
        ti_info = isnothing(ti) ? "" : " (dependency of $(repr(ti.name)))"
        printstyled(io, "Captured logs"; bold=true, color=Base.info_color())
        print(io, " for test setup \"$(setup.name)\"$(ti_info) at ")
        printstyled(io, _file_info(setup); bold=true, color=:default)
        println(io, isnothing(ti) ? _on_worker() : _on_worker(ti))
        open(logpath(setup), "r") do logstore
            write(io, logstore)
        end
    end
    return nothing
end

# Calling this function directly will always print *something* for the test item, either
# the captured logs or a messgage that no logs were captured. `print_errors_and_captured_logs`
# will call this function only if some logs were collected or when called with `verbose_results`.
function _print_captured_logs(io, ti::TestItem, run_number::Int)
    for setup in ti.testsetups
        _print_captured_logs(io, setup, ti)
    end
    has_logs = _has_logs(ti, run_number)
    bold_text = has_logs ? "Captured Logs" : "No Captured Logs"
    printstyled(io, bold_text; bold=true, color=Base.info_color())
    print(io, " for test item $(repr(ti.name)) at ")
    printstyled(io, _file_info(ti); bold=true, color=:default)
    println(io, _on_worker(ti))
    has_logs && open(logpath(ti, run_number), "r") do logstore
        write(io, logstore)
    end
    return nothing
end

# Adapted from Test.print_test_errors to print into an IOBuffer and to report worker id if needed
function _print_test_errors(report_iob, ts::DefaultTestSet, worker_info)
    for result in ts.results
        if isa(result, Test.Error) || isa(result, Test.Fail)
            println(report_iob, "Error in testset $(repr(ts.description))$(worker_info):")
            show(report_iob, result)
            println(report_iob)
        elseif isa(result, DefaultTestSet)
            _print_test_errors(report_iob, result, worker_info)
        end
    end
    return nothing
end

# Marks the start of each test item
function log_running(ti::TestItem, ntestitems=0)
    io = IOContext(IOBuffer(), :color=>Base.get_have_color())
    print(io, format(now(), "HH:MM:SS "))
    printstyled(io, "RUNNING "; bold=true)
    if ntestitems > 0
        print(io, " (", lpad(ti.eval_number[], ndigits(ntestitems)), "/", ntestitems, ")")
    end
    print(io, " test item $(repr(ti.name)) at ")
    printstyled(io, _file_info(ti); bold=true, color=:default)
    println(io)
    @loglock write(DEFAULT_STDOUT[], take!(io.io))
end

# mostly copied from timing.jl
function log_finished(ti::TestItem, ntestitems=0)
    io = IOContext(IOBuffer(), :color=>Base.get_have_color())
    print(io, format(now(), "HH:MM:SS "))
    printstyled(io, "FINISHED"; bold=true)
    if ntestitems > 0
        print(io, " (", lpad(ti.eval_number[], ndigits(ntestitems)), "/", ntestitems, ")")
    end
    print(io, " test item $(repr(ti.name)) ")
    x = last(ti.stats) # always stats for most recent run
    time_print(io; x.elapsedtime, x.bytes, x.gctime, x.allocs, x.compile_time, x.recompile_time)
    println(io)
    @loglock write(DEFAULT_STDOUT[], take!(io.io))
end

function report_empty_testsets(ti::TestItem, ts::DefaultTestSet)
    empty_testsets = String[]
    _find_empty_testsets!(empty_testsets, ts)
    if !isempty(empty_testsets)
        @warn """
            Test item $(repr(ti.name)) at $(_file_info(ti)) contains test sets without tests:
            $(join(empty_testsets, '\n'))
            """
    end
    return nothing
end

function _find_empty_testsets!(empty_testsets::Vector{String}, ts::DefaultTestSet)
    if (isempty(ts.results) && ts.n_passed == 0)
        push!(empty_testsets, repr(ts.description))
        return nothing
    end
    for result in ts.results
        isa(result, DefaultTestSet) && _find_empty_testsets!(empty_testsets, result)
    end
    return nothing
end
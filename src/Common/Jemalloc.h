#pragma once

#include "config.h"

#if USE_JEMALLOC

#include <string>
#include <unordered_map>
#include <Common/logger_useful.h>
#include <base/types.h>
#include <jemalloc/jemalloc.h>

namespace DB
{

struct ServerSettings;

namespace Jemalloc
{

void purgeArenas();

void checkProfilingEnabled();

void setProfileActive(bool value);

std::string_view flushProfile(const std::string & file_prefix);

void setBackgroundThreads(bool enabled);

void setMaxBackgroundThreads(size_t max_threads);

template <typename T>
void setValue(const char * name, T value)
{
    mallctl(name, nullptr, nullptr, reinterpret_cast<void*>(&value), sizeof(T));
}

template <typename T>
T getValue(const char * name)
{
    T value;
    size_t value_size = sizeof(T);
    mallctl(name, &value, &value_size, nullptr, 0);
    return value;
}

void setup(
    bool enable_global_profiler,
    bool enable_background_threads,
    size_t max_background_threads_num,
    bool collect_global_profile_samples_in_trace_log);

/// Each mallctl call consists of string name lookup which can be expensive.
/// This can be avoided by translating name to "Management Information Base" (MIB)
/// and using it in mallctlbymib calls
template <typename T>
struct MibCache
{
    explicit MibCache(const char * name)
    {
        mallctlnametomib(name, mib, &mib_length);
    }

    void setValue(T value) const
    {
        mallctlbymib(mib, mib_length, nullptr, nullptr, reinterpret_cast<void*>(&value), sizeof(T));
    }

    T getValue() const
    {
        T value;
        size_t value_size = sizeof(T);
        mallctlbymib(mib, mib_length, &value, &value_size, nullptr, 0);
        return value;
    }

    void run() const
    {
        mallctlbymib(mib, mib_length, nullptr, nullptr, nullptr, 0);
    }

private:
    static constexpr size_t max_mib_length = 4;
    size_t mib[max_mib_length];
    size_t mib_length = max_mib_length;
};

const MibCache<bool> & getThreadProfileActiveMib();
const MibCache<bool> & getThreadProfileInitMib();

void setCollectLocalProfileSamplesInTraceLog(bool value);

std::string_view getLastFlushProfileForThread();

/// Cache mapping address -> symbolized name (e.g. "func1--inline2--inline3").
/// Pass the same cache to multiple symbolizeHeapProfile() calls to avoid
/// redundant DWARF lookups for addresses shared across heap files.
using SymbolCache = std::unordered_map<UInt64, std::string>;

/// Convert a jemalloc heap profile to symbolized format that jeprof can read without binary.
/// This generates a "jeprof --raw" compatible format with embedded symbols.
///
/// Notes:
/// - demangling code slightly differs (i.e. it may return "operator()" instead of "DB::Context::initializeSystemLogs()::$_0::operator()() const")
void symbolizeHeapProfile(const std::string & input_filename, const std::string & output_filename);

/// Overload with a shared symbol cache.
/// Addresses already in the cache are not re-symbolized (skips DWARF lookup).
/// The cache is populated with any new addresses found in the file.
void symbolizeHeapProfile(const std::string & input_filename, const std::string & output_filename, SymbolCache & cache);

}

}

#endif

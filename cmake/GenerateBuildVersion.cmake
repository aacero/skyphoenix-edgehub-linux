cmake_minimum_required(VERSION 3.22)

foreach(_required XENEON_SOURCE_DIR XENEON_OUTPUT_FILE XENEON_FALLBACK_VERSION)
    if(NOT DEFINED ${_required} OR "${${_required}}" STREQUAL "")
        message(FATAL_ERROR "${_required} is required")
    endif()
endforeach()

set(_version "")
if(DEFINED XENEON_VERSION_OVERRIDE AND NOT XENEON_VERSION_OVERRIDE STREQUAL "")
    set(_version "${XENEON_VERSION_OVERRIDE}")
elseif(DEFINED XENEON_GIT_EXECUTABLE
       AND NOT XENEON_GIT_EXECUTABLE STREQUAL "")
    execute_process(
        COMMAND "${XENEON_GIT_EXECUTABLE}" -C "${XENEON_SOURCE_DIR}"
                describe --tags --always --dirty
        RESULT_VARIABLE _git_result
        OUTPUT_VARIABLE _version
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
    if(NOT _git_result EQUAL 0)
        set(_version "")
    endif()
endif()

if(_version STREQUAL "")
    set(_version "${XENEON_FALLBACK_VERSION}")
endif()
string(REGEX REPLACE "^v" "" _version "${_version}")
if(_version MATCHES "[\r\n]")
    message(FATAL_ERROR "build version must be a single line")
endif()
message(STATUS "Xeneon build version: ${_version}")

# Encode the identity as one C string literal. Git ref names reject newlines,
# backslashes and several other unsafe characters, but an explicit packaging
# override is caller-controlled, so escape the two characters meaningful here.
string(REPLACE "\\" "\\\\" _escaped_version "${_version}")
string(REPLACE "\"" "\\\"" _escaped_version "${_escaped_version}")
set(_header
    "#pragma once\n#define XENEON_VERSION \"${_escaped_version}\"\n")

get_filename_component(_output_dir "${XENEON_OUTPUT_FILE}" DIRECTORY)
file(MAKE_DIRECTORY "${_output_dir}")
string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef _candidate_suffix)
set(_candidate "${XENEON_OUTPUT_FILE}.${_candidate_suffix}.tmp")
file(WRITE "${_candidate}" "${_header}")
execute_process(
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${_candidate}" "${XENEON_OUTPUT_FILE}"
    RESULT_VARIABLE _copy_result)
file(REMOVE "${_candidate}")
if(NOT _copy_result EQUAL 0)
    message(FATAL_ERROR "could not publish ${XENEON_OUTPUT_FILE}")
endif()

# Generator-specific release tooling checks.
#
# CPack includes this file after it resolves the actual generator (including a
# command-line `cpack -G ...` override). Keep distro package creation fail-closed:
# CPackDeb otherwise warns about missing dpkg tools but still exits successfully
# with a malformed package whose Architecture is empty and whose linked-library
# dependencies were never derived.

if(CPACK_GENERATOR STREQUAL "DEB")
    find_program(XENEON_CPACK_DPKG NAMES dpkg)
    find_program(XENEON_CPACK_DPKG_SHLIBDEPS NAMES dpkg-shlibdeps)
    if(NOT XENEON_CPACK_DPKG OR NOT EXISTS "${XENEON_CPACK_DPKG}"
       OR NOT XENEON_CPACK_DPKG_SHLIBDEPS
       OR NOT EXISTS "${XENEON_CPACK_DPKG_SHLIBDEPS}")
        message(FATAL_ERROR
            "DEB packaging requires both dpkg and dpkg-shlibdeps (install "
            "dpkg-dev on Debian/Ubuntu). Refusing to emit an invalid .deb; "
            "build DEB artifacts on the supported distro image instead.")
    endif()
    if(CPACK_XENEON_NATIVE_PACKAGE_VERSION)
        set(CPACK_PACKAGE_VERSION "${CPACK_XENEON_NATIVE_PACKAGE_VERSION}")
    endif()
    message(STATUS "Xeneon CPack DEB version: ${CPACK_PACKAGE_VERSION}")
elseif(CPACK_GENERATOR STREQUAL "RPM")
    find_program(XENEON_CPACK_RPMBUILD NAMES rpmbuild)
    if(NOT XENEON_CPACK_RPMBUILD OR NOT EXISTS "${XENEON_CPACK_RPMBUILD}")
        message(FATAL_ERROR
            "RPM packaging requires rpmbuild. Refusing to emit a partial RPM; "
            "build RPM artifacts on the supported Fedora image instead.")
    endif()
    if(CPACK_XENEON_NATIVE_PACKAGE_VERSION)
        set(CPACK_PACKAGE_VERSION "${CPACK_XENEON_NATIVE_PACKAGE_VERSION}")
    endif()
    message(STATUS "Xeneon CPack RPM version: ${CPACK_PACKAGE_VERSION}")
endif()

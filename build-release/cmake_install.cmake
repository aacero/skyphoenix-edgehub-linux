# Install script for directory: /home/simon/IdeaProjects/XeneonEdge_Linux

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "/usr/local")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Release")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Install shared libraries without execute permission?
if(NOT DEFINED CMAKE_INSTALL_SO_NO_EXE)
  set(CMAKE_INSTALL_SO_NO_EXE "0")
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

# Set path to fallback-tool for dependency-resolution.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/usr/bin/objdump")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-hub" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-hub")
    file(RPATH_CHECK
         FILE "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-hub"
         RPATH "")
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/bin" TYPE EXECUTABLE FILES "/home/simon/IdeaProjects/XeneonEdge_Linux/build-release/xeneon-edge-hub")
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-hub" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-hub")
    if(CMAKE_INSTALL_DO_STRIP)
      execute_process(COMMAND "/usr/bin/strip" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-hub")
    endif()
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  include("/home/simon/IdeaProjects/XeneonEdge_Linux/build-release/CMakeFiles/xeneon-edge-hub.dir/install-cxx-module-bmi-Release.cmake" OPTIONAL)
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-manager" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-manager")
    file(RPATH_CHECK
         FILE "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-manager"
         RPATH "")
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/bin" TYPE EXECUTABLE FILES "/home/simon/IdeaProjects/XeneonEdge_Linux/build-release/xeneon-edge-manager")
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-manager" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-manager")
    if(CMAKE_INSTALL_DO_STRIP)
      execute_process(COMMAND "/usr/bin/strip" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/xeneon-edge-manager")
    endif()
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  include("/home/simon/IdeaProjects/XeneonEdge_Linux/build-release/CMakeFiles/xeneon-edge-manager.dir/install-cxx-module-bmi-Release.cmake" OPTIONAL)
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/applications" TYPE FILE FILES
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/xeneon-edge-hub.desktop"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/xeneon-edge-manager.desktop"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/metainfo" TYPE FILE FILES
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/metainfo/com.skyphoenix_it.XeneonEdgeHub.metainfo.xml"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/metainfo/com.skyphoenix_it.XeneonEdgeManager.metainfo.xml"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/icons/hicolor/scalable/apps" TYPE FILE FILES
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/xeneon-edge-hub.svg"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/xeneon-edge-manager.svg"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/icons/hicolor/16x16/apps" TYPE FILE FILES
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/16x16/apps/xeneon-edge-hub.png"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/16x16/apps/xeneon-edge-manager.png"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/icons/hicolor/32x32/apps" TYPE FILE FILES
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/32x32/apps/xeneon-edge-hub.png"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/32x32/apps/xeneon-edge-manager.png"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/icons/hicolor/48x48/apps" TYPE FILE FILES
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/48x48/apps/xeneon-edge-hub.png"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/48x48/apps/xeneon-edge-manager.png"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/icons/hicolor/64x64/apps" TYPE FILE FILES
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/64x64/apps/xeneon-edge-hub.png"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/64x64/apps/xeneon-edge-manager.png"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/icons/hicolor/128x128/apps" TYPE FILE FILES
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/128x128/apps/xeneon-edge-hub.png"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/128x128/apps/xeneon-edge-manager.png"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/icons/hicolor/256x256/apps" TYPE FILE FILES
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/256x256/apps/xeneon-edge-hub.png"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/256x256/apps/xeneon-edge-manager.png"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/icons/hicolor/512x512/apps" TYPE FILE FILES
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/512x512/apps/xeneon-edge-hub.png"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icon/hicolor/512x512/apps/xeneon-edge-manager.png"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/licenses/xeneon-edge-hub" TYPE FILE FILES
    "/home/simon/IdeaProjects/XeneonEdge_Linux/LICENSE"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/LICENSE-MIT"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/LICENSE-APACHE"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/packaging/THIRD_PARTY_NOTICES-RUST.txt"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/icons/LICENSE-MIT-PhosphorIcons.txt"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/fonts/LICENSE-OFL-AtkinsonHyperlegible.txt"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/fonts/LICENSE-OFL-ChakraPetch.txt"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/fonts/LICENSE-OFL-Inter.txt"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/fonts/LICENSE-OFL-JetBrainsMono.txt"
    "/home/simon/IdeaProjects/XeneonEdge_Linux/assets/fonts/LICENSE-OFL-Lexend.txt"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/doc/xeneon-edge-hub" TYPE FILE FILES "/home/simon/IdeaProjects/XeneonEdge_Linux/packaging/debian/copyright")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/udev/rules.d" TYPE FILE OPTIONAL FILES "/home/simon/IdeaProjects/XeneonEdge_Linux/packaging/udev/99-xeneon-edge.rules")
endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
if(CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "/home/simon/IdeaProjects/XeneonEdge_Linux/build-release/install_local_manifest.txt"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()
if(CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_COMPONENT MATCHES "^[a-zA-Z0-9_.+-]+$")
    set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INSTALL_COMPONENT}.txt")
  else()
    string(MD5 CMAKE_INST_COMP_HASH "${CMAKE_INSTALL_COMPONENT}")
    set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INST_COMP_HASH}.txt")
    unset(CMAKE_INST_COMP_HASH)
  endif()
else()
  set(CMAKE_INSTALL_MANIFEST "install_manifest.txt")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "/home/simon/IdeaProjects/XeneonEdge_Linux/build-release/${CMAKE_INSTALL_MANIFEST}"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()

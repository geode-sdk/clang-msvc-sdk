# When configuring CMake with a toolchain file against a top-level CMakeLists.txt,
# it will actually run CMake many times, once for each small test program used to
# determine what features a compiler supports.  Unfortunately, none of these
# invocations share a CMakeCache.txt with the top-level invocation, meaning they
# won't see the value of any arguments the user passed via -D.  Since these are
# necessary to properly configure MSVC in both the top-level configuration as well as
# all feature-test invocations, we set environment variables with the values so that
# these environments get inherited by child invocations.
function(init_user_prop prop)
  if(${prop})
    set(ENV{_${prop}} "${${prop}}")
  else()
    set(${prop} "$ENV{_${prop}}" PARENT_SCOPE)
  endif()
endfunction()

macro(cmake_getconf VAR)
  if(NOT ${VAR})
    set(${VAR} "$ENV{${VAR}}")
    if(${VAR})
      set(${VAR} "${${VAR}}" CACHE STRING "${VAR}")
      message(STATUS "Found ${VAR}: ${${VAR}}")
    elseif(${ARGC} GREATER 1)
      set(${VAR} "${ARGV1}" CACHE STRING "${ARGV1}")
      message(STATUS "Found ${VAR}: ${${VAR}}")
    else()
      message(FATAL_ERROR "Cannot determine \"${VAR}\"")
    endif()
  else()
    set(ENV{${VAR}} "${${VAR}}")
  endif()
endmacro()

macro(cmake_getconf_opt VAR)
  if(NOT ${VAR})
    set(${VAR} "$ENV{${VAR}}")
    if(${VAR})
      set(${VAR} "${${VAR}}" CACHE STRING "${VAR}")
      message(STATUS "Found ${VAR}: ${${VAR}}")
    else()
      message(STATUS "\"${VAR}\" not set, leaving blank")
    endif()
  else()
    set(ENV{${VAR}} "${${VAR}}")
  endif()
endmacro()

function(generate_winsdk_vfs_overlay winsdk_include_dir output_path)
  set(include_dirs)
  file(GLOB_RECURSE entries LIST_DIRECTORIES true "${winsdk_include_dir}/*")
  foreach(entry ${entries})
    if(IS_DIRECTORY "${entry}")
      list(APPEND include_dirs "${entry}")
    endif()
  endforeach()

  file(WRITE "${output_path}"  "version: 0\n")
  file(APPEND "${output_path}" "case-sensitive: false\n")
  file(APPEND "${output_path}" "roots:\n")

  foreach(dir ${include_dirs})
    file(GLOB headers RELATIVE "${dir}" "${dir}/*.h")
    if(NOT headers)
      continue()
    endif()

    file(APPEND "${output_path}" "  - name: \"${dir}\"\n")
    file(APPEND "${output_path}" "    type: directory\n")
    file(APPEND "${output_path}" "    contents:\n")

    foreach(header ${headers})
      file(APPEND "${output_path}" "      - name: \"${header}\"\n")
      file(APPEND "${output_path}" "        type: file\n")
      file(APPEND "${output_path}" "        external-contents: \"${dir}/${header}\"\n")
    endforeach()
  endforeach()
endfunction()

function(generate_winsdk_lib_symlinks winsdk_um_lib_dir output_dir)
  message(STATUS "Generating library symlinks to ${output_dir}")
  execute_process(COMMAND "${CMAKE_COMMAND}" -E make_directory "${output_dir}")
  file(GLOB libraries RELATIVE "${winsdk_um_lib_dir}" "${winsdk_um_lib_dir}/*")
  foreach(library ${libraries})
    string(TOLOWER "${library}" symlink_name)
    execute_process(COMMAND "${CMAKE_COMMAND}"
                            -E create_symlink
                            "${winsdk_um_lib_dir}/${library}"
                            "${output_dir}/${symlink_name}")
  endforeach()
endfunction()

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_VERSION 10.0)
set(CMAKE_SYSTEM_PROCESSOR AMD64)

cmake_getconf(SPLAT_DIR)
cmake_getconf(HOST_ARCH x86)
cmake_getconf_opt(LLVM_VER)
cmake_getconf_opt(CLANG_VER)
cmake_getconf_opt(LLVM_PATH)

if(HOST_ARCH STREQUAL "aarch64" OR HOST_ARCH STREQUAL "arm64")
  set(TRIPLE_ARCH "aarch64")
  set(WINSDK_ARCH "arm64")
elseif(HOST_ARCH STREQUAL "armv7" OR HOST_ARCH STREQUAL "arm")
  set(TRIPLE_ARCH "armv7")
  set(WINSDK_ARCH "arm")
elseif(HOST_ARCH STREQUAL "i686" OR HOST_ARCH STREQUAL "x86")
  set(TRIPLE_ARCH "i686")
  set(WINSDK_ARCH "x86")
elseif(HOST_ARCH STREQUAL "x86_64" OR HOST_ARCH STREQUAL "x64")
  set(TRIPLE_ARCH "x86_64")
  set(WINSDK_ARCH "x86_64")
else()
  message(SEND_ERROR "Unknown host architecture ${HOST_ARCH}. Must be aarch64 (or arm64), armv7 (or arm), i686 (or x86), or x86_64 (or x64).")
endif()

set(MSVC_INCLUDE "${SPLAT_DIR}/crt/include")
set(MSVC_LIB "${SPLAT_DIR}/crt/lib")
set(WINSDK_INCLUDE "${SPLAT_DIR}/sdk/include")
set(WINSDK_LIB "${SPLAT_DIR}/sdk/lib")

if(NOT EXISTS "${MSVC_INCLUDE}" OR NOT EXISTS "${MSVC_LIB}" OR NOT EXISTS "${WINSDK_INCLUDE}" OR NOT EXISTS "${WINSDK_LIB}")
  message(SEND_ERROR
          "CMake variable SPLAT_DIR must point to a folder containing the xwin splat.")
endif()

if(NOT EXISTS "${WINSDK_INCLUDE}/um/Windows.h")
  message(SEND_ERROR "Cannot find Windows.h")
endif()
if(NOT EXISTS "${WINSDK_INCLUDE}/um/WINDOWS.H")
  set(case_sensitive_filesystem TRUE)
endif()

# Attempt to find the llvm-link binary
find_program(LLD_LINK_PATH NAMES lld-link-${LLVM_VER} lld-link lld-link-18 lld-link-17 lld-link-16 lld-link-15 lld-link-14 lld-link-13 PATHS ${LLVM_PATH})
if(${LLD_LINK_PATH} STREQUAL "LLD_LINK_PATH-NOTFOUND")
  message(SEND_ERROR "Unable to find lld-link")
endif()

# Attempt to find the llvm-ar binary
find_program(LLVM_AR_PATH NAMES llvm-ar-${LLVM_VER} llvm-ar llvm-ar-18 llvm-ar-17 llvm-ar-16 llvm-ar-15 llvm-ar-14 llvm-ar-13 PATHS ${LLVM_PATH})
if(${LLVM_AR_PATH} STREQUAL "LLVM_AR_PATH-NOTFOUND")
  message(SEND_ERROR "Unable to find llvm-ar")
endif()

# Attempt to find the llvm-nm binary
find_program(LLVM_NM_PATH NAMES llvm-nm-${LLVM_VER} llvm-nm llvm-nm-18 llvm-nm-17 llvm-nm-16 llvm-nm-15 llvm-nm-14 llvm-nm-13 PATHS ${LLVM_PATH})
if(${LLVM_NM_PATH} STREQUAL "LLVM_NM_PATH-NOTFOUND")
  message(SEND_ERROR "Unable to find llvm-nm")
endif()

# Attempt to find the llvm-mt binary
find_program(LLVM_MT_PATH NAMES llvm-mt-${LLVM_VER} llvm-mt llvm-mt-18 llvm-mt-17 llvm-mt-16 llvm-mt-15 llvm-mt-14 llvm-mt-13 PATHS ${LLVM_PATH})
#set(LLVM_MT_PATH "${CMAKE_CURRENT_LIST_DIR}/llvm-mt-wrapper")
if(${LLVM_MT_PATH} STREQUAL "LLVM_MT_PATH-NOTFOUND")
  message(SEND_ERROR "Unable to find llvm-mt")
endif()

# Attempt to find the native clang binary
find_program(CLANG_C_PATH NAMES clang-${CLANG_VER} clang clang-18 clang-17 clang-16 clang-15 clang-14 clang-13 PATHS ${LLVM_PATH})
if(${CLANG_C_PATH} STREQUAL "CLANG_C_PATH-NOTFOUND")
  message(SEND_ERROR "Unable to find clang")
endif()

# Attempt to find the native clang++ binary
find_program(CLANG_CXX_PATH NAMES clang++-${CLANG_VER} clang++ clang++-18 clang++-17 clang++-16 clang++-15 clang++-14 clang++-13 PATHS ${LLVM_PATH})
if(${CLANG_CXX_PATH} STREQUAL "CLANG_CXX_PATH-NOTFOUND")
  message(SEND_ERROR "Unable to find clang++")
endif()

# Attempt to find the llvm-rc binary
find_program(LLVM_RC_PATH NAMES llvm-rc-${LLVM_VER} llvm-rc llvm-rc-18 llvm-rc-17 llvm-rc-16 llvm-rc-15 llvm-rc-14 llvm-rc-13 PATHS ${LLVM_PATH})
if(${LLVM_RC_PATH} STREQUAL "LLVM_RC_PATH-NOTFOUND")
  message(SEND_ERROR "Unable to find rc")
endif()


set(CMAKE_C_COMPILER "${CLANG_C_PATH}" CACHE FILEPATH "")
set(CMAKE_CXX_COMPILER "${CLANG_CXX_PATH}" CACHE FILEPATH "")
set(CMAKE_RC_COMPILER "${LLVM_RC_PATH}" CACHE FILEPATH "")
set(CMAKE_LINKER "${LLD_LINK_PATH}" CACHE FILEPATH "")
set(CMAKE_AR "${LLVM_AR_PATH}" CACHE FILEPATH "")
set(CMAKE_NM "${LLVM_NM_PATH}" CACHE FILEPATH "")
set(CMAKE_MT "${LLVM_MT_PATH}" CACHE FILEPATH "")

# Even though we're cross-compiling, we need some native tools (e.g. llvm-tblgen), and those
# native tools have to be built before we can start doing the cross-build.  LLVM supports
# a CROSS_TOOLCHAIN_FLAGS_NATIVE argument which consists of a list of flags to pass to CMake
# when configuring the NATIVE portion of the cross-build.  By default we construct this so
# that it points to the tools in the same location as the native clang-cl that we're using.
list(APPEND _CTF_NATIVE_DEFAULT "-DCMAKE_ASM_COMPILER=${CLANG_C_PATH}")
list(APPEND _CTF_NATIVE_DEFAULT "-DCMAKE_C_COMPILER=${CLANG_C_PATH}")
list(APPEND _CTF_NATIVE_DEFAULT "-DCMAKE_CXX_COMPILER=${CLANG_CXX_PATH}")

set(CROSS_TOOLCHAIN_FLAGS_NATIVE "${_CTF_NATIVE_DEFAULT}" CACHE STRING "")

cmake_path(GET CLANG_C_PATH PARENT_PATH LLVM_BIN_DIR)

execute_process(COMMAND ${CMAKE_CXX_COMPILER} --version OUTPUT_VARIABLE CLANG_VERSION_OUTPUT)
string(REGEX MATCH "[0-9]+\\.[0-9]+\\.[0-9]+" CLANG_FULL_VERSION ${CLANG_VERSION_OUTPUT})
string(REGEX REPLACE "([0-9]+)\\..*" "\\1" CLANG_MAJOR_VERSION ${CLANG_FULL_VERSION})

message(STATUS "LLVM major version: ${CLANG_MAJOR_VERSION}")

set(COMPILE_FLAGS
    -fexceptions -fcxx-exceptions
    -D_CRT_SECURE_NO_WARNINGS
    --target=${TRIPLE_ARCH}-windows-msvc
    -fms-compatibility-version=19.37
    -Wno-unused-command-line-argument # Needed to accept projects pushing both -Werror and /MP
    # following line is to make SIMD intrinsics work with clang (clang-cl works fine without this)
    -isystem "${LLVM_BIN_DIR}/../lib/clang/${CLANG_MAJOR_VERSION}/include"
    -isystem"${MSVC_INCLUDE}"
    -isystem"${WINSDK_INCLUDE}/ucrt"
    -isystem"${WINSDK_INCLUDE}/shared"
    -isystem"${WINSDK_INCLUDE}/um"
    -isystem"${WINSDK_INCLUDE}/winrt")

link_libraries(user32 kernel32 shell32 ole32 crypt32 advapi32 delayimp gdi32)

if(case_sensitive_filesystem)
  # Ensure all sub-configures use the top-level VFS overlay instead of generating their own.
  init_user_prop(winsdk_vfs_overlay_path)
  if(NOT winsdk_vfs_overlay_path)
    set(winsdk_vfs_overlay_path "${CMAKE_BINARY_DIR}/winsdk_vfs_overlay.yaml")
    generate_winsdk_vfs_overlay("${WINSDK_INCLUDE}" "${winsdk_vfs_overlay_path}")
    init_user_prop(winsdk_vfs_overlay_path)
  endif()
  list(APPEND COMPILE_FLAGS -ivfsoverlay"${winsdk_vfs_overlay_path}")

  #set(CMAKE_CLANG_VFS_OVERLAY "${winsdk_vfs_overlay_path}")
endif()

string(REPLACE ";" " " COMPILE_FLAGS "${COMPILE_FLAGS}")

# We need to preserve any flags that were passed in by the user. However, we
# can't append to CMAKE_C_FLAGS and friends directly, because toolchain files
# will be re-invoked on each reconfigure and therefore need to be idempotent.
# The assignments to the _INITIAL cache variables don't use FORCE, so they'll
# only be populated on the initial configure, and their values won't change
# afterward.
set(_CMAKE_RC_FLAGS_INITIAL -I"${MSVC_INCLUDE}"
                            -I"${WINSDK_INCLUDE}/ucrt"
                            -I"${WINSDK_INCLUDE}/shared"
                            -I"${WINSDK_INCLUDE}/um"
                            -I"${WINSDK_INCLUDE}/winrt")
string(REPLACE ";" " " _CMAKE_RC_FLAGS_INITIAL "${_CMAKE_RC_FLAGS_INITIAL}")
set(CMAKE_RC_FLAGS "${_CMAKE_RC_FLAGS_INITIAL}" CACHE STRING "" FORCE)

set(_CMAKE_C_FLAGS_INITIAL "${CMAKE_C_FLAGS}" CACHE STRING "")
set(CMAKE_C_FLAGS "${_CMAKE_C_FLAGS_INITIAL} ${COMPILE_FLAGS}" CACHE STRING "" FORCE)

set(_CMAKE_CXX_FLAGS_INITIAL "${CMAKE_CXX_FLAGS}" CACHE STRING "")
set(CMAKE_CXX_FLAGS "${_CMAKE_CXX_FLAGS_INITIAL} ${COMPILE_FLAGS}" CACHE STRING "" FORCE)

set(LINK_FLAGS
    # Prevent CMake from attempting to invoke mt.exe. It only recognizes the slashed form and not the dashed form.
    #/manifest:no

    -L"${MSVC_LIB}/${WINSDK_ARCH}"
    -L"${WINSDK_LIB}/ucrt/${WINSDK_ARCH}"
    -L"${WINSDK_LIB}/um/${WINSDK_ARCH}")

if(case_sensitive_filesystem)
  # Ensure all sub-configures use the top-level symlinks dir instead of generating their own.
  init_user_prop(winsdk_lib_symlinks_dir)
  if(NOT winsdk_lib_symlinks_dir)
    set(winsdk_lib_symlinks_dir "${CMAKE_BINARY_DIR}/winsdk_lib_symlinks")
  endif()

  # check if the directory exists
  if (EXISTS "${winsdk_lib_symlinks_dir}")
    file(GLOB existing_symlinks "${winsdk_lib_symlinks_dir}/*")
    if (existing_symlinks)
      message(STATUS "Using existing symlinks, skipping generation")
    else()
      generate_winsdk_lib_symlinks("${WINSDK_LIB}/um/${WINSDK_ARCH}" "${winsdk_lib_symlinks_dir}")
    endif()
  else()
    generate_winsdk_lib_symlinks("${WINSDK_LIB}/um/${WINSDK_ARCH}" "${winsdk_lib_symlinks_dir}")
  endif()

  init_user_prop(winsdk_lib_symlinks_dir)
  list(APPEND LINK_FLAGS
        -L"${winsdk_lib_symlinks_dir}")
endif()

string(REPLACE ";" " " LINK_FLAGS "${LINK_FLAGS}")

# See explanation for compiler flags above for the _INITIAL variables.
set(_CMAKE_EXE_LINKER_FLAGS_INITIAL "${CMAKE_EXE_LINKER_FLAGS}" CACHE STRING "")
set(CMAKE_EXE_LINKER_FLAGS "${_CMAKE_EXE_LINKER_FLAGS_INITIAL} ${LINK_FLAGS}" CACHE STRING "" FORCE)

set(_CMAKE_MODULE_LINKER_FLAGS_INITIAL "${CMAKE_MODULE_LINKER_FLAGS}" CACHE STRING "")
set(CMAKE_MODULE_LINKER_FLAGS "${_CMAKE_MODULE_LINKER_FLAGS_INITIAL} ${LINK_FLAGS}" CACHE STRING "" FORCE)

set(_CMAKE_SHARED_LINKER_FLAGS_INITIAL "${CMAKE_SHARED_LINKER_FLAGS}" CACHE STRING "")
set(CMAKE_SHARED_LINKER_FLAGS "${_CMAKE_SHARED_LINKER_FLAGS_INITIAL} ${LINK_FLAGS}" CACHE STRING "" FORCE)

# CMake populates these with a bunch of unnecessary libraries, which requires
# extra case-correcting symlinks and what not. Instead, let projects explicitly
# control which libraries they require.
set(CMAKE_C_STANDARD_LIBRARIES "" CACHE STRING "" FORCE)
set(CMAKE_CXX_STANDARD_LIBRARIES "" CACHE STRING "" FORCE)

if(NOT $ENV{VCPKG_TOOLCHAIN} STREQUAL "")
  message(STATUS "Included VCPKG: $ENV{VCPKG_TOOLCHAIN}")
  include($ENV{VCPKG_TOOLCHAIN})
endif()

cmake_minimum_required(VERSION 3.10)

set(BUILD_SHARED_LIBS ON)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

if(ANDROID)
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DANDROID_ARM_NEON=TRUE -DANDROID_TOOLCHAIN=clang -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-23")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -DANDROID_ARM_NEON=TRUE -DANDROID_TOOLCHAIN=clang -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-23")
    # Log the flags
    message(STATUS "CMAKE_C_FLAGS: ${CMAKE_C_FLAGS}")
endif()

#set(LLAMA_STATIC ON CACHE BOOL "llama: enable static link libraries" FORCE)
set(LLAMA_NATIVE OFF CACHE BOOL "llama: disable -march=native flag" FORCE)

set(LLAMA_CPP_DIR "${CMAKE_SOURCE_DIR}/../third_party/llama.cpp")
if(EXISTS "${LLAMA_CPP_DIR}" AND NOT IS_DIRECTORY "${LLAMA_CPP_DIR}")
    get_filename_component(LLAMA_CPP_LINK_BASE "${LLAMA_CPP_DIR}" DIRECTORY)
    file(READ "${LLAMA_CPP_DIR}" LLAMA_CPP_LINK_RAW)
    string(STRIP "${LLAMA_CPP_LINK_RAW}" LLAMA_CPP_LINK_RAW)
    if(LLAMA_CPP_LINK_RAW)
        if(IS_ABSOLUTE "${LLAMA_CPP_LINK_RAW}")
            set(LLAMA_CPP_DIR "${LLAMA_CPP_LINK_RAW}")
        else()
            get_filename_component(
                LLAMA_CPP_DIR
                "${LLAMA_CPP_LINK_BASE}/${LLAMA_CPP_LINK_RAW}"
                ABSOLUTE
            )
        endif()
    endif()
endif()

if(NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "llama.cpp not found at ${LLAMA_CPP_DIR}. Run tool/fetch_llama_cpp.py")
endif()

add_subdirectory("${LLAMA_CPP_DIR}" llama_cpp_build)

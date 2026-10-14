cmake_minimum_required(VERSION 3.16)
project(c7shell-greeter LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick DBus Network)

set(C7_GREETER_DIR "${CMAKE_INSTALL_PREFIX}/share/c7shell/greeter" CACHE STRING "")

# Where the remembered account is kept. Must be writable by the greeter user.
set(C7_STATE_DIR "/var/lib/c7shell-greeter" CACHE STRING "")

add_executable(c7shell-greeter main.cpp greetd.cpp models.cpp config.cpp)
target_compile_definitions(c7shell-greeter PRIVATE
  C7_GREETER_DIR="${C7_GREETER_DIR}" C7_STATE_DIR="${C7_STATE_DIR}")
target_link_libraries(c7shell-greeter PRIVATE
  Qt6::Gui Qt6::Qml Qt6::Quick Qt6::DBus Qt6::Network)

install(TARGETS c7shell-greeter RUNTIME DESTINATION bin)

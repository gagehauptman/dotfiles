cmake_minimum_required(VERSION 3.21)
project(bevyqml LANGUAGES CXX)

# The QML plugin has no link-time dependency on any app: BevyView dlopens the
# app library named by its `library` property at runtime.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick)
qt_standard_project_setup(REQUIRES 6.5)

qt_add_qml_module(bevyqml
    URI Bevy
    VERSION 1.0
    PLUGIN_TARGET bevyqml
    OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/Bevy"
    SOURCES bevyview.h bevyview.cpp
)
target_link_libraries(bevyqml PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick ${CMAKE_DL_LIBS})

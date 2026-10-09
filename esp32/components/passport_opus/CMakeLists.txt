set(PASSPORT_OPUS_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../shared/opus/Sources/PassportOpus")
include("${CMAKE_CURRENT_LIST_DIR}/../../../shared/opus/sources.cmake")
idf_component_register(SRCS ${PASSPORT_OPUS_SOURCES} "${PASSPORT_OPUS_ROOT}/passport_opus.c"
    INCLUDE_DIRS "${PASSPORT_OPUS_ROOT}/public"
    PRIV_INCLUDE_DIRS "${PASSPORT_OPUS_ROOT}" "${PASSPORT_OPUS_ROOT}/include" "${PASSPORT_OPUS_ROOT}/celt" "${PASSPORT_OPUS_ROOT}/silk" "${PASSPORT_OPUS_ROOT}/silk/fixed")
target_compile_definitions(${COMPONENT_LIB} PRIVATE HAVE_CONFIG_H)

set(LLVM_TARGET_DEFINITIONS TransformDialectExtension.td)
mlir_tablegen(TransformDialectExtension.h.inc -gen-op-decls)
mlir_tablegen(TransformDialectExtension.cpp.inc -gen-op-defs)
mlir_tablegen(TransformDialectExtensionTypes.h.inc -gen-typedef-decls -typedefs-dialect=transform)
mlir_tablegen(TransformDialectExtensionTypes.cpp.inc -gen-typedef-defs -typedefs-dialect=transform)
add_public_tablegen_target(MLIROneFlowTransformDialectExtensionIncGen)

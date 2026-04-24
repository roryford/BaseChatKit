import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct BaseChatMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ToolSchemaMacro.self,
    ]
}

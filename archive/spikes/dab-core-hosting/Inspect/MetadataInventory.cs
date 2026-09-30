using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
static class MetadataInventory {
public static void Run(IEnumerable<string> paths) {
foreach (var path in paths.Order())
{
    using var stream = File.OpenRead(path);
    using var pe = new PEReader(stream);
    var reader = pe.GetMetadataReader();
    var assembly = reader.GetAssemblyDefinition();
    Console.WriteLine($"ASSEMBLY {reader.GetString(assembly.Name)} {assembly.Version} FILE {Path.GetFileName(path)}");
    foreach (var handle in reader.AssemblyReferences)
    {
        var reference = reader.GetAssemblyReference(handle);
        Console.WriteLine($"  REFERENCES {reader.GetString(reference.Name)} {reference.Version}");
    }
    foreach (var handle in reader.TypeDefinitions)
    {
        var type = reader.GetTypeDefinition(handle);
        var visibility = type.Attributes & TypeAttributes.VisibilityMask;
        if (visibility is not (TypeAttributes.Public or TypeAttributes.NestedPublic)) continue;
        Console.WriteLine($"  TYPE {reader.GetString(type.Namespace)}.{reader.GetString(type.Name)}");
        foreach (var methodHandle in type.GetMethods())
        {
            var method = reader.GetMethodDefinition(methodHandle);
            if ((method.Attributes & MethodAttributes.MemberAccessMask) != MethodAttributes.Public) continue;
            var parameters = method.GetParameters().Select(h => reader.GetString(reader.GetParameter(h).Name));
            Console.WriteLine($"    {method.Attributes} {reader.GetString(method.Name)}({string.Join(", ", parameters)})");
        }
    }
}

}}

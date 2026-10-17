using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Interop.UIAutomationClient;

// Load the production sensor without starting its Windows-only worker thread.
var sensorType = typeof(LifeNarrator.Windows.BubbleStyle).Assembly.GetType("LifeNarrator.Windows.ContextSensor")!;
const BindingFlags fields = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
var unsubscribe = sensorType.GetMethod("UnsubscribeScroll", fields)!;
var handlerType = sensorType.GetNestedType("ScrollEvents", BindingFlags.NonPublic)!;
void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
object? Get(object sensor, string field) => sensorType.GetField(field, fields)!.GetValue(sensor);
void Set(object sensor, string field, object? value) => sensorType.GetField(field, fields)!.SetValue(sensor, value);
void Remove(object sensor) => unsubscribe.Invoke(sensor, null);

foreach (var failure in new Exception?[] { null, new UnauthorizedAccessException("provider access denied"), new COMException("provider gone", unchecked((int)0x80040201)) })
{
    var sensor = RuntimeHelpers.GetUninitializedObject(sensorType);
    var failures = new List<string>();
    Set(sensor, "failed", (Action<string>)failures.Add);
    var root = DispatchProxy.Create<IUIAutomationElement, UiaProxy>();
    var handler = Activator.CreateInstance(handlerType, fields, null, [(Action)(() => { })], null)!;
    var automation = DispatchProxy.Create<IUIAutomation, UiaProxy>();
    var removes = 0;
    ((UiaProxy)(object)automation).InvokeMethod = (method, args) =>
    {
        Require(method.Name == "RemovePropertyChangedEventHandler", "Unexpected UIA call: " + method.Name);
        removes++;
        Require(ReferenceEquals(args![0], root) && ReferenceEquals(args[1], handler), "Removed the wrong subscription");
        Require(Get(sensor, "scrollRoot") == null && Get(sensor, "scrollEvents") == null, "Local subscription survived into provider call");
        if (failure != null) throw failure;
        return null;
    };
    Set(sensor, "automation", automation);
    Set(sensor, "scrollRoot", root); Set(sensor, "scrollEvents", handler);
    Remove(sensor);
    Require(removes == 1, "Provider was not called exactly once");
    Require(failures.SequenceEqual(failure == null ? [] : new[] { "UIA: " + failure.Message }), "Removal failure was not visible exactly once");
    // A subsequent switch or shutdown must not retry the same dead provider.
    Remove(sensor); Remove(sensor);
    Require(removes == 1 && failures.Count == (failure == null ? 0 : 1), "Failed subscription was retried");
    // A fresh capture can register a new pair and still be cleaned up normally.
    Set(sensor, "scrollRoot", root); Set(sensor, "scrollEvents", handler);
    ((UiaProxy)(object)automation).InvokeMethod = (_, args) =>
    {
        removes++;
        Require(Get(sensor, "scrollRoot") == null && Get(sensor, "scrollEvents") == null, "Rearmed subscription not cleared before cleanup");
        return null;
    };
    Remove(sensor);
    Require(removes == 2 && Get(sensor, "scrollRoot") == null && Get(sensor, "scrollEvents") == null, "Rearmed cleanup failed");
}

// Do not turn unrelated programming failures into recoverable provider errors.
{
    var sensor = RuntimeHelpers.GetUninitializedObject(sensorType);
    Set(sensor, "failed", (Action<string>)(_ => throw new Exception("Unexpected failure callback")));
    Set(sensor, "scrollRoot", DispatchProxy.Create<IUIAutomationElement, UiaProxy>());
    Set(sensor, "scrollEvents", Activator.CreateInstance(handlerType, fields, null, [(Action)(() => { })], null));
    var automation = DispatchProxy.Create<IUIAutomation, UiaProxy>();
    var bug = new NullReferenceException("test programming error");
    ((UiaProxy)(object)automation).InvokeMethod = (_, _) => throw bug;
    Set(sensor, "automation", automation);
    try { Remove(sensor); throw new Exception("Unrelated exception was swallowed"); }
    catch (TargetInvocationException error) when (ReferenceEquals(error.InnerException, bug)) { }
    Require(Get(sensor, "scrollRoot") == null && Get(sensor, "scrollEvents") == null, "Unexpected failure retained stale subscription");
}
Console.WriteLine("PASS: production sensor unsubscribe clears state before UIA, reports access denied/COM errors once, never retries stale pairs, permits rearm, and propagates unrelated errors");

public class UiaProxy : DispatchProxy
{
    public Func<MethodInfo, object?[]?, object?> InvokeMethod = (method, _) => throw new Exception("Unexpected UIA call: " + method.Name);
    protected override object? Invoke(MethodInfo? targetMethod, object?[]? args) => InvokeMethod(targetMethod!, args);
}

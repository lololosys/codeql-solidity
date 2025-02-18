/**
 * Provides an implementation of  _API graphs_, which are an abstract representation of the API
 * surface used and/or defined by a code base.
 *
 * The nodes of the API graph represent definitions and uses of API components. The edges are
 * directed and labeled; they specify how the components represented by nodes relate to each other.
 */

private import ruby
private import codeql.ruby.DataFlow
private import codeql.ruby.typetracking.TypeTracker
private import codeql.ruby.ast.internal.Module
private import codeql.ruby.controlflow.CfgNodes
private import codeql.ruby.dataflow.internal.DataFlowPrivate as DataFlowPrivate
private import codeql.ruby.dataflow.internal.DataFlowDispatch as DataFlowDispatch

/**
 * Provides classes and predicates for working with APIs used in a database.
 */
module API {
  /**
   * A node in the API graph, representing a value that has crossed the boundary between this
   * codebase and an external library (or in general, any external codebase).
   *
   * ### Basic usage
   *
   * API graphs are typically used to identify "API calls", that is, calls to an external function
   * whose implementation is not necessarily part of the current codebase.
   *
   * The most basic use of API graphs is typically as follows:
   * 1. Start with `API::getTopLevelMember` for the relevant library.
   * 2. Follow up with a chain of accessors such as `getMethod` describing how to get to the relevant API function.
   * 3. Map the resulting API graph nodes to data-flow nodes, using `asSource` or `asSink`.
   *
   * For example, a simplified way to get arguments to `Foo.bar` would be
   * ```codeql
   * API::getTopLevelMember("Foo").getMethod("bar").getParameter(0).asSink()
   * ```
   *
   * The most commonly used accessors are `getMember`, `getMethod`, `getParameter`, and `getReturn`.
   *
   * ### API graph nodes
   *
   * There are two kinds of nodes in the API graphs, distinguished by who is "holding" the value:
   * - **Use-nodes** represent values held by the current codebase, which came from an external library.
   *   (The current codebase is "using" a value that came from the library).
   * - **Def-nodes** represent values held by the external library, which came from this codebase.
   *   (The current codebase "defines" the value seen by the library).
   *
   * API graph nodes are associated with data-flow nodes in the current codebase.
   * (Since external libraries are not part of the database, there is no way to associate with concrete
   * data-flow nodes from the external library).
   * - **Use-nodes** are associated with data-flow nodes where a value enters the current codebase,
   *   such as the return value of a call to an external function.
   * - **Def-nodes** are associated with data-flow nodes where a value leaves the current codebase,
   *   such as an argument passed in a call to an external function.
   *
   *
   * ### Access paths and edge labels
   *
   * Nodes in the API graph are associated with a set of access paths, describing a series of operations
   * that may be performed to obtain that value.
   *
   * For example, the access path `API::getTopLevelMember("Foo").getMethod("bar")` represents the action of
   * reading the top-level constant `Foo` and then accessing the method `bar` on the resulting object.
   * It would be associated with a call such as `Foo.bar()`.
   *
   * Each edge in the graph is labelled by such an "operation". For an edge `A->B`, the type of the `A` node
   * determines who is performing the operation, and the type of the `B` node determines who ends up holding
   * the result:
   * - An edge starting from a use-node describes what the current codebase is doing to a value that
   *   came from a library.
   * - An edge starting from a def-node describes what the external library might do to a value that
   *   came from the current codebase.
   * - An edge ending in a use-node means the result ends up in the current codebase (at its associated data-flow node).
   * - An edge ending in a def-node means the result ends up in external code (its associated data-flow node is
   *   the place where it was "last seen" in the current codebase before flowing out)
   *
   * Because the implementation of the external library is not visible, it is not known exactly what operations
   * it will perform on values that flow there. Instead, the edges starting from a def-node are operations that would
   * lead to an observable effect within the current codebase; without knowing for certain if the library will actually perform
   * those operations. (When constructing these edges, we assume the library is somewhat well-behaved).
   *
   * For example, given this snippet:
   * ```ruby
   * Foo.bar(->(x) { doSomething(x) })
   * ```
   * A callback is passed to the external function `Foo.bar`. We can't know if `Foo.bar` will actually invoke this callback.
   * But _if_ the library should decide to invoke the callback, then a value will flow into the current codebase via the `x` parameter.
   * For that reason, an edge is generated representing the argument-passing operation that might be performed by `Foo.bar`.
   * This edge is going from the def-node associated with the callback to the use-node associated with the parameter `x` of the lambda.
   */
  class Node extends Impl::TApiNode {
    /**
     * Gets a data-flow node where this value may flow after entering the current codebase.
     *
     * This is similar to `asSource()` but additionally includes nodes that are transitively reachable by data flow.
     * See `asSource()` for examples.
     */
    DataFlow::Node getAValueReachableFromSource() {
      exists(DataFlow::LocalSourceNode src | Impl::use(this, src) |
        Impl::trackUseNode(src).flowsTo(result)
      )
    }

    /**
     * Gets a data-flow node where this value enters the current codebase.
     *
     * For example:
     * ```ruby
     * # API::getTopLevelMember("Foo").asSource()
     * Foo
     *
     * # API::getTopLevelMember("Foo").getMethod("bar").getReturn().asSource()
     * Foo.bar
     *
     * # 'x' is found by:
     * # API::getTopLevelMember("Foo").getMethod("bar").getBlock().getParameter(0).asSource()
     * Foo.bar do |x|
     * end
     * ```
     */
    DataFlow::LocalSourceNode asSource() { Impl::use(this, result) }

    /**
     * Gets a data-flow node where this value leaves the current codebase and flows into an
     * external library (or in general, any external codebase).
     *
     * Concretely, this corresponds to an argument passed to a call to external code.
     *
     * For example:
     * ```ruby
     * # 'x' is found by:
     * # API::getTopLevelMember("Foo").getMethod("bar").getParameter(0).asSink()
     * Foo.bar(x)
     *
     * Foo.bar(-> {
     *   # 'x' is found by:
     *   # API::getTopLevelMember("Foo").getMethod("bar").getParameter(0).getReturn().asSink()
     *   x
     * })
     * ```
     */
    DataFlow::Node asSink() { Impl::def(this, result) }

    /**
     * Get a data-flow node that transitively flows to an external library (or in general, any external codebase).
     *
     * This is similar to `asSink()` but additionally includes nodes that transitively reach a sink by data flow.
     * See `asSink()` for examples.
     */
    DataFlow::Node getAValueReachingSink() { result = Impl::trackDefNode(this.asSink()) }

    /** DEPRECATED. This predicate has been renamed to `getAValueReachableFromSource()`. */
    deprecated DataFlow::Node getAUse() { result = this.getAValueReachableFromSource() }

    /** DEPRECATED. This predicate has been renamed to `asSource()`. */
    deprecated DataFlow::LocalSourceNode getAnImmediateUse() { result = this.asSource() }

    /** DEPRECATED. This predicate has been renamed to `asSink()`. */
    deprecated DataFlow::Node getARhs() { result = this.asSink() }

    /** DEPRECATED. This predicate has been renamed to `getAValueReachingSink()`. */
    deprecated DataFlow::Node getAValueReachingRhs() { result = this.getAValueReachingSink() }

    /**
     * Gets a call to a method on the receiver represented by this API component.
     */
    DataFlow::CallNode getAMethodCall(string method) { result = this.getReturn(method).asSource() }

    /**
     * Gets a node representing member `m` of this API component.
     *
     * For example, a member can be:
     *
     * - A submodule of a module
     * - An attribute of an object
     */
    bindingset[m]
    bindingset[result]
    Node getMember(string m) { result = this.getASuccessor(Label::member(m)) }

    /**
     * Gets a node representing a member of this API component where the name of the member is
     * not known statically.
     */
    Node getUnknownMember() { result = this.getASuccessor(Label::unknownMember()) }

    /**
     * Gets a node representing a member of this API component where the name of the member may
     * or may not be known statically.
     */
    Node getAMember() {
      result = this.getASuccessor(Label::member(_)) or
      result = this.getUnknownMember()
    }

    /**
     * Gets a node representing an instance of this API component, that is, an object whose
     * constructor is the function represented by this node.
     *
     * For example, if this node represents a use of some class `A`, then there might be a node
     * representing instances of `A`, typically corresponding to expressions `A.new` at the
     * source level.
     *
     * This predicate may have multiple results when there are multiple constructor calls invoking this API component.
     * Consider using `getAnInstantiation()` if there is a need to distinguish between individual constructor calls.
     */
    Node getInstance() { result = this.getASubclass().getReturn("new") }

    /**
     * Gets a node representing a call to `method` on the receiver represented by this node.
     */
    Node getMethod(string method) {
      result = this.getASubclass().getASuccessor(Label::method(method))
    }

    /**
     * Gets a node representing the result of this call.
     */
    Node getReturn() { result = this.getASuccessor(Label::return()) }

    /**
     * Gets a node representing the result of calling a method on the receiver represented by this node.
     */
    Node getReturn(string method) { result = this.getMethod(method).getReturn() }

    /** Gets an API node representing the `n`th positional parameter. */
    pragma[nomagic]
    Node getParameter(int n) { result = this.getASuccessor(Label::parameter(n)) }

    /** Gets an API node representing the given keyword parameter. */
    pragma[nomagic]
    Node getKeywordParameter(string name) {
      result = this.getASuccessor(Label::keywordParameter(name))
    }

    /** Gets an API node representing the block parameter. */
    Node getBlock() { result = this.getASuccessor(Label::blockParameter()) }

    /**
     * Gets a `new` call to the function represented by this API component.
     */
    DataFlow::ExprNode getAnInstantiation() { result = this.getInstance().asSource() }

    /**
     * Gets a node representing a (direct or indirect) subclass of the class represented by this node.
     * ```rb
     * class A; end
     * class B < A; end
     * class C < B; end
     * ```
     * In the example above, `getMember("A").getASubclass()` will return uses of `A`, `B` and `C`.
     */
    Node getASubclass() { result = this.getAnImmediateSubclass*() }

    /**
     * Gets a node representing a direct subclass of the class represented by this node.
     * ```rb
     * class A; end
     * class B < A; end
     * class C < B; end
     * ```
     * In the example above, `getMember("A").getAnImmediateSubclass()` will return uses of `B` only.
     */
    Node getAnImmediateSubclass() { result = this.getASuccessor(Label::subclass()) }

    /**
     * Gets a string representation of the lexicographically least among all shortest access paths
     * from the root to this node.
     */
    string getPath() {
      result = min(string p | p = this.getAPath(Impl::distanceFromRoot(this)) | p)
    }

    /**
     * Gets a node such that there is an edge in the API graph between this node and the other
     * one, and that edge is labeled with `lbl`.
     */
    Node getASuccessor(Label::ApiLabel lbl) { Impl::edge(this, lbl, result) }

    /**
     * Gets a node such that there is an edge in the API graph between that other node and
     * this one, and that edge is labeled with `lbl`
     */
    Node getAPredecessor(Label::ApiLabel lbl) { this = result.getASuccessor(lbl) }

    /**
     * Gets a node such that there is an edge in the API graph between this node and the other
     * one.
     */
    Node getAPredecessor() { result = this.getAPredecessor(_) }

    /**
     * Gets a node such that there is an edge in the API graph between that other node and
     * this one.
     */
    Node getASuccessor() { result = this.getASuccessor(_) }

    /**
     * Gets the data-flow node that gives rise to this node, if any.
     */
    DataFlow::Node getInducingNode() {
      this = Impl::MkUse(result)
      or
      this = Impl::MkDef(result)
      or
      this = Impl::MkMethodAccessNode(result)
    }

    /** Gets the location of this node. */
    Location getLocation() {
      result = this.getInducingNode().getLocation()
      or
      // For nodes that do not have a meaningful location, `path` is the empty string and all other
      // parameters are zero.
      not exists(this.getInducingNode()) and
      result instanceof EmptyLocation
    }

    /**
     * Gets a textual representation of this element.
     */
    abstract string toString();

    /**
     * Gets a path of the given `length` from the root to this node.
     */
    private string getAPath(int length) {
      this instanceof Impl::MkRoot and
      length = 0 and
      result = ""
      or
      exists(Node pred, Label::ApiLabel lbl, string predpath |
        Impl::edge(pred, lbl, this) and
        predpath = pred.getAPath(length - 1) and
        exists(string dot | if length = 1 then dot = "" else dot = "." |
          result = predpath + dot + lbl and
          // avoid producing strings longer than 1MB
          result.length() < 1000 * 1000
        )
      ) and
      length in [1 .. Impl::distanceFromRoot(this)]
    }

    /** Gets the shortest distance from the root to this node in the API graph. */
    int getDepth() { result = Impl::distanceFromRoot(this) }
  }

  /** The root node of an API graph. */
  class Root extends Node, Impl::MkRoot {
    override string toString() { result = "root" }
  }

  private string tryGetPath(Node node) {
    result = node.getPath()
    or
    not exists(node.getPath()) and
    result = "with no path"
  }

  /** A node corresponding to the use of an API component. */
  class Use extends Node, Impl::MkUse {
    override string toString() { result = "Use " + tryGetPath(this) }
  }

  /** A node corresponding to a value escaping into an API component. */
  class Def extends Node, Impl::MkDef {
    override string toString() { result = "Def " + tryGetPath(this) }
  }

  /** A node corresponding to the method being invoked at a method call. */
  class MethodAccessNode extends Node, Impl::MkMethodAccessNode {
    override string toString() { result = "MethodAccessNode " + tryGetPath(this) }

    /** Gets the call node corresponding to this method access. */
    DataFlow::CallNode getCallNode() { this = Impl::MkMethodAccessNode(result) }
  }

  /**
   * An API entry point.
   *
   * By default, API graph nodes are only created for nodes that come from an external
   * library or escape into an external library. The points where values are cross the boundary
   * between codebases are called "entry points".
   *
   * Anything in the global scope is considered to be an entry point, but
   * additional entry points may be added by extending this class.
   */
  abstract class EntryPoint extends string {
    bindingset[this]
    EntryPoint() { any() }

    /** Gets a data-flow node corresponding to a use-node for this entry point. */
    DataFlow::LocalSourceNode getAUse() { none() }

    /** Gets a data-flow node corresponding to a def-node for this entry point. */
    DataFlow::Node getARhs() { none() }

    /** Gets a call corresponding to a method access node for this entry point. */
    DataFlow::CallNode getACall() { none() }

    /** Gets an API-node for this entry point. */
    API::Node getANode() { result = root().getASuccessor(Label::entryPoint(this)) }
  }

  // Ensure all entry points are imported from ApiGraphs.qll
  private module ImportEntryPoints {
    private import codeql.ruby.frameworks.data.ModelsAsData
  }

  /** Gets the root node. */
  Root root() { any() }

  /**
   * Gets a node corresponding to a top-level member `m` (typically a module).
   *
   * This is equivalent to `root().getAMember("m")`.
   *
   * Note: You should only use this predicate for top level modules or classes. If you want nodes corresponding to a nested module or class,
   * you should use `.getMember` on the parent module/class. For example, for nodes corresponding to the class `Gem::Version`,
   * use `getTopLevelMember("Gem").getMember("Version")`.
   */
  Node getTopLevelMember(string m) { result = root().getMember(m) }

  /**
   * Provides the actual implementation of API graphs, cached for performance.
   *
   * Ideally, we'd like nodes to correspond to (global) access paths, with edge labels
   * corresponding to extending the access path by one element. We also want to be able to map
   * nodes to their definitions and uses in the data-flow graph, and this should happen modulo
   * (inter-procedural) data flow.
   *
   * This, however, is not easy to implement, since access paths can have unbounded length
   * and we need some way of recognizing cycles to avoid non-termination. Unfortunately, expressing
   * a condition like "this node hasn't been involved in constructing any predecessor of
   * this node in the API graph" without negative recursion is tricky.
   *
   * So instead most nodes are directly associated with a data-flow node, representing
   * either a use or a definition of an API component. This ensures that we only have a finite
   * number of nodes. However, we can now have multiple nodes with the same access
   * path, which are essentially indistinguishable for a client of the API.
   *
   * On the other hand, a single node can have multiple access paths (which is, of
   * course, unavoidable). We pick as canonical the alphabetically least access path with
   * shortest length.
   */
  cached
  private module Impl {
    cached
    newtype TApiNode =
      /** The root of the API graph. */
      MkRoot() or
      /** The method accessed at `call`, synthetically treated as a separate object. */
      MkMethodAccessNode(DataFlow::CallNode call) { isUse(call) } or
      /** A use of an API member at the node `nd`. */
      MkUse(DataFlow::Node nd) { isUse(nd) } or
      /** A value that escapes into an external library at the node `nd` */
      MkDef(DataFlow::Node nd) { isDef(nd) }

    private string resolveTopLevel(ConstantReadAccess read) {
      TResolved(result) = resolveConstantReadAccess(read) and
      not result.matches("%::%")
    }

    /**
     * Holds if `ref` is a use of a node that should have an incoming edge from the root
     * node labeled `lbl` in the API graph (not including those from API::EntryPoint).
     */
    pragma[nomagic]
    private predicate useRoot(Label::ApiLabel lbl, DataFlow::Node ref) {
      exists(string name, ConstantReadAccess read |
        read = ref.asExpr().getExpr() and
        lbl = Label::member(read.getName())
      |
        name = resolveTopLevel(read)
        or
        name = read.getName() and
        not exists(resolveTopLevel(read)) and
        not exists(read.getScopeExpr())
      )
    }

    /**
     * Holds if `ref` is a use of a node that should have an incoming edge labeled `lbl`,
     * from a use node that flows to `node`.
     */
    private predicate useStep(Label::ApiLabel lbl, DataFlow::Node node, DataFlow::Node ref) {
      // // Referring to an attribute on a node that is a use of `base`:
      // pred = `Rails` part of `Rails::Whatever`
      // lbl = `Whatever`
      // ref = `Rails::Whatever`
      exists(ExprNodes::ConstantAccessCfgNode c, ConstantReadAccess read |
        not exists(resolveTopLevel(read)) and
        node.asExpr() = c.getScopeExpr() and
        lbl = Label::member(read.getName()) and
        ref.asExpr() = c and
        read = c.getExpr()
      )
      // note: method calls are not handled here as there is no DataFlow::Node for the intermediate MkMethodAccessNode API node
    }

    pragma[nomagic]
    private predicate isUse(DataFlow::Node nd) {
      useRoot(_, nd)
      or
      exists(DataFlow::Node node |
        useCandFwd().flowsTo(node) and
        useStep(_, node, nd)
      )
      or
      useCandFwd().flowsTo(nd.(DataFlow::CallNode).getReceiver())
      or
      parameterStep(_, defCand(), nd)
      or
      nd = any(EntryPoint entry).getAUse()
      or
      nd = any(EntryPoint entry).getACall()
    }

    /**
     * Holds if `ref` is a use of node `nd`.
     */
    cached
    predicate use(TApiNode nd, DataFlow::Node ref) { nd = MkUse(ref) }

    /**
     * Holds if `rhs` is a RHS of node `nd`.
     */
    cached
    predicate def(TApiNode nd, DataFlow::Node rhs) { nd = MkDef(rhs) }

    /** Gets a node reachable from a use-node. */
    private DataFlow::LocalSourceNode useCandFwd(TypeTracker t) {
      t.start() and
      isUse(result)
      or
      exists(TypeTracker t2 | result = useCandFwd(t2).track(t2, t))
    }

    /** Gets a node reachable from a use-node. */
    private DataFlow::LocalSourceNode useCandFwd() { result = useCandFwd(TypeTracker::end()) }

    private DataFlow::Node useCandRev(TypeBackTracker tb) {
      result = useCandFwd() and
      tb.start()
      or
      exists(TypeBackTracker tb2, DataFlow::LocalSourceNode mid, TypeTracker t |
        mid = useCandRev(tb2) and
        result = mid.backtrack(tb2, tb) and
        pragma[only_bind_out](result) = useCandFwd(t) and
        pragma[only_bind_out](t) = pragma[only_bind_out](tb).getACompatibleTypeTracker()
      )
    }

    private DataFlow::LocalSourceNode useCandRev() {
      result = useCandRev(TypeBackTracker::end()) and
      isUse(result)
    }

    private predicate isDef(DataFlow::Node rhs) {
      // If a call node is relevant as a use-node, treat its arguments as def-nodes
      argumentStep(_, useCandFwd(), rhs)
      or
      rhs = any(EntryPoint entry).getARhs()
    }

    /** Gets a data flow node that flows to the RHS of a def-node. */
    private DataFlow::LocalSourceNode defCand(TypeBackTracker t) {
      t.start() and
      exists(DataFlow::Node rhs |
        isDef(rhs) and
        result = rhs.getALocalSource()
      )
      or
      exists(TypeBackTracker t2 | result = defCand(t2).backtrack(t2, t))
    }

    /** Gets a data flow node that flows to the RHS of a def-node. */
    private DataFlow::LocalSourceNode defCand() { result = defCand(TypeBackTracker::end()) }

    /**
     * Holds if there should be a `lbl`-edge from the given call to an argument.
     */
    pragma[nomagic]
    private predicate argumentStep(
      Label::ApiLabel lbl, DataFlow::CallNode call, DataFlowPrivate::ArgumentNode argument
    ) {
      exists(DataFlowDispatch::ArgumentPosition argPos |
        argument.sourceArgumentOf(call.asExpr(), argPos) and
        lbl = Label::getLabelFromArgumentPosition(argPos)
      )
    }

    /**
     * Holds if there should be a `lbl`-edge from the given callable to a parameter.
     */
    pragma[nomagic]
    private predicate parameterStep(
      Label::ApiLabel lbl, DataFlow::Node callable, DataFlowPrivate::ParameterNodeImpl paramNode
    ) {
      exists(DataFlowDispatch::ParameterPosition paramPos |
        paramNode.isSourceParameterOf(callable.asExpr().getExpr(), paramPos) and
        lbl = Label::getLabelFromParameterPosition(paramPos)
      )
    }

    /**
     * Gets a data-flow node to which `src`, which is a use of an API-graph node, flows.
     *
     * The flow from `src` to the returned node may be inter-procedural.
     */
    private DataFlow::Node trackUseNode(DataFlow::LocalSourceNode src, TypeTracker t) {
      result = src and
      result = useCandRev() and
      t.start()
      or
      exists(TypeTracker t2, DataFlow::LocalSourceNode mid, TypeBackTracker tb |
        mid = trackUseNode(src, t2) and
        result = mid.track(t2, t) and
        pragma[only_bind_out](result) = useCandRev(tb) and
        pragma[only_bind_out](t) = pragma[only_bind_out](tb).getACompatibleTypeTracker()
      )
    }

    /**
     * Gets a data-flow node to which `src`, which is a use of an API-graph node, flows.
     *
     * The flow from `src` to the returned node may be inter-procedural.
     */
    cached
    DataFlow::LocalSourceNode trackUseNode(DataFlow::LocalSourceNode src) {
      result = trackUseNode(src, TypeTracker::end())
    }

    /** Gets a data flow node reaching the RHS of the given def node. */
    private DataFlow::LocalSourceNode trackDefNode(DataFlow::Node rhs, TypeBackTracker t) {
      t.start() and
      isDef(rhs) and
      result = rhs.getALocalSource()
      or
      exists(TypeBackTracker t2 | result = trackDefNode(rhs, t2).backtrack(t2, t))
    }

    /** Gets a data flow node reaching the RHS of the given def node. */
    cached
    DataFlow::LocalSourceNode trackDefNode(DataFlow::Node rhs) {
      result = trackDefNode(rhs, TypeBackTracker::end())
    }

    pragma[nomagic]
    private predicate useNodeReachesReceiver(DataFlow::Node use, DataFlow::CallNode call) {
      trackUseNode(use).flowsTo(call.getReceiver())
    }

    /**
     * Holds if there is an edge from `pred` to `succ` in the API graph that is labeled with `lbl`.
     */
    cached
    predicate edge(TApiNode pred, Label::ApiLabel lbl, TApiNode succ) {
      /* Every node that is a use of an API component is itself added to the API graph. */
      exists(DataFlow::LocalSourceNode ref | succ = MkUse(ref) |
        pred = MkRoot() and
        useRoot(lbl, ref)
        or
        exists(DataFlow::Node node, DataFlow::Node src |
          pred = MkUse(src) and
          trackUseNode(src).flowsTo(node) and
          useStep(lbl, node, ref)
        )
        or
        exists(DataFlow::Node callback |
          pred = MkDef(callback) and
          parameterStep(lbl, trackDefNode(callback), ref)
        )
      )
      or
      // `pred` is a use of class A
      // `succ` is a use of class B
      // there exists a class declaration B < A
      exists(ClassDeclaration c, DataFlow::Node a, DataFlow::Node b |
        use(pred, a) and
        use(succ, b) and
        resolveConstant(b.asExpr().getExpr()) = resolveConstantWriteAccess(c) and
        pragma[only_bind_into](c).getSuperclassExpr() = a.asExpr().getExpr() and
        lbl = Label::subclass()
      )
      or
      exists(DataFlow::CallNode call |
        // from receiver to method call node
        exists(DataFlow::Node receiver |
          pred = MkUse(receiver) and
          useNodeReachesReceiver(receiver, call) and
          lbl = Label::method(call.getMethodName()) and
          succ = MkMethodAccessNode(call)
        )
        or
        // from method call node to return and arguments
        pred = MkMethodAccessNode(call) and
        (
          lbl = Label::return() and
          succ = MkUse(call)
          or
          exists(DataFlow::Node rhs |
            argumentStep(lbl, call, rhs) and
            succ = MkDef(rhs)
          )
        )
      )
      or
      exists(EntryPoint entry |
        pred = root() and
        lbl = Label::entryPoint(entry)
      |
        succ = MkDef(entry.getARhs())
        or
        succ = MkUse(entry.getAUse())
        or
        succ = MkMethodAccessNode(entry.getACall())
      )
    }

    /**
     * Holds if there is an edge from `pred` to `succ` in the API graph.
     */
    private predicate edge(TApiNode pred, TApiNode succ) { edge(pred, _, succ) }

    /** Gets the shortest distance from the root to `nd` in the API graph. */
    cached
    int distanceFromRoot(TApiNode nd) = shortestDistances(MkRoot/0, edge/2)(_, nd, result)

    /** All the possible labels in the API graph. */
    cached
    newtype TLabel =
      MkLabelMember(string member) { member = any(ConstantReadAccess a).getName() } or
      MkLabelUnknownMember() or
      MkLabelMethod(string m) { m = any(DataFlow::CallNode c).getMethodName() } or
      MkLabelReturn() or
      MkLabelSubclass() or
      MkLabelKeywordParameter(string name) {
        any(DataFlowDispatch::ArgumentPosition arg).isKeyword(name)
        or
        any(DataFlowDispatch::ParameterPosition arg).isKeyword(name)
      } or
      MkLabelParameter(int n) {
        any(DataFlowDispatch::ArgumentPosition c).isPositional(n)
        or
        any(DataFlowDispatch::ParameterPosition c).isPositional(n)
      } or
      MkLabelBlockParameter() or
      MkLabelEntryPoint(EntryPoint name)
  }

  /** Provides classes modeling the various edges (labels) in the API graph. */
  module Label {
    /** A label in the API-graph */
    class ApiLabel extends Impl::TLabel {
      /** Gets a string representation of this label. */
      string toString() { result = "???" }
    }

    private import LabelImpl

    private module LabelImpl {
      private import Impl

      /** A label for a member, for example a constant. */
      class LabelMember extends ApiLabel, MkLabelMember {
        private string member;

        LabelMember() { this = MkLabelMember(member) }

        /** Gets the member name associated with this label. */
        string getMember() { result = member }

        override string toString() { result = "getMember(\"" + member + "\")" }
      }

      /** A label for a member with an unknown name. */
      class LabelUnknownMember extends ApiLabel, MkLabelUnknownMember {
        override string toString() { result = "getUnknownMember()" }
      }

      /** A label for a method. */
      class LabelMethod extends ApiLabel, MkLabelMethod {
        private string method;

        LabelMethod() { this = MkLabelMethod(method) }

        /** Gets the method name associated with this label. */
        string getMethod() { result = method }

        override string toString() { result = "getMethod(\"" + method + "\")" }
      }

      /** A label for the return value of a method. */
      class LabelReturn extends ApiLabel, MkLabelReturn {
        override string toString() { result = "getReturn()" }
      }

      /** A label for the subclass relationship. */
      class LabelSubclass extends ApiLabel, MkLabelSubclass {
        override string toString() { result = "getASubclass()" }
      }

      /** A label for a keyword parameter. */
      class LabelKeywordParameter extends ApiLabel, MkLabelKeywordParameter {
        private string name;

        LabelKeywordParameter() { this = MkLabelKeywordParameter(name) }

        /** Gets the name of the keyword parameter associated with this label. */
        string getName() { result = name }

        override string toString() { result = "getKeywordParameter(\"" + name + "\")" }
      }

      /** A label for a parameter. */
      class LabelParameter extends ApiLabel, MkLabelParameter {
        private int n;

        LabelParameter() { this = MkLabelParameter(n) }

        /** Gets the parameter number associated with this label. */
        int getIndex() { result = n }

        override string toString() { result = "getParameter(" + n + ")" }
      }

      /** A label for a block parameter. */
      class LabelBlockParameter extends ApiLabel, MkLabelBlockParameter {
        override string toString() { result = "getBlock()" }
      }

      /** A label from the root node to a custom entry point. */
      class LabelEntryPoint extends ApiLabel, MkLabelEntryPoint {
        private API::EntryPoint name;

        LabelEntryPoint() { this = MkLabelEntryPoint(name) }

        override string toString() { result = name }

        /** Gets the name of the entry point. */
        API::EntryPoint getName() { result = name }
      }
    }

    /** Gets the `member` edge label for member `m`. */
    LabelMember member(string m) { result.getMember() = m }

    /** Gets the `member` edge label for the unknown member. */
    LabelUnknownMember unknownMember() { any() }

    /** Gets the `method` edge label. */
    LabelMethod method(string m) { result.getMethod() = m }

    /** Gets the `return` edge label. */
    LabelReturn return() { any() }

    /** Gets the `subclass` edge label. */
    LabelSubclass subclass() { any() }

    /** Gets the label representing the given keword argument/parameter. */
    LabelKeywordParameter keywordParameter(string name) { result.getName() = name }

    /** Gets the label representing the `n`th positional argument/parameter. */
    LabelParameter parameter(int n) { result.getIndex() = n }

    /** Gets the label representing the block argument/parameter. */
    LabelBlockParameter blockParameter() { any() }

    /** Gets the label for the edge from the root node to a custom entry point of the given name. */
    LabelEntryPoint entryPoint(API::EntryPoint name) { result.getName() = name }

    /** Gets the API graph label corresponding to the given argument position. */
    Label::ApiLabel getLabelFromArgumentPosition(DataFlowDispatch::ArgumentPosition pos) {
      exists(int n |
        pos.isPositional(n) and
        result = Label::parameter(n)
      )
      or
      exists(string name |
        pos.isKeyword(name) and
        result = Label::keywordParameter(name)
      )
      or
      pos.isBlock() and
      result = Label::blockParameter()
      or
      pos.isAny() and
      (
        result = Label::parameter(_)
        or
        result = Label::keywordParameter(_)
        or
        result = Label::blockParameter()
        // NOTE: `self` should NOT be included, as described in the QLDoc for `isAny()`
      )
      or
      pos.isAnyNamed() and
      result = Label::keywordParameter(_)
      //
      // Note: there is currently no API graph label for `self`.
      // It was omitted since in practice it means going back to where you came from.
      // For example, `base.getMethod("foo").getSelf()` would just be `base`.
      // However, it's possible we'll need it later, for identifying `self` parameters or post-update nodes.
    }

    /** Gets the API graph label corresponding to the given parameter position. */
    Label::ApiLabel getLabelFromParameterPosition(DataFlowDispatch::ParameterPosition pos) {
      exists(int n |
        pos.isPositional(n) and
        result = Label::parameter(n)
      )
      or
      exists(string name |
        pos.isKeyword(name) and
        result = Label::keywordParameter(name)
      )
      or
      pos.isBlock() and
      result = Label::blockParameter()
      or
      pos.isAny() and
      (
        result = Label::parameter(_)
        or
        result = Label::keywordParameter(_)
        or
        result = Label::blockParameter()
        // NOTE: `self` should NOT be included, as described in the QLDoc for `isAny()`
      )
      or
      pos.isAnyNamed() and
      result = Label::keywordParameter(_)
      //
      // Note: there is currently no API graph label for `self`.
      // It was omitted since in practice it means going back to where you came from.
      // For example, `base.getMethod("foo").getSelf()` would just be `base`.
      // However, it's possible we'll need it later, for identifying `self` parameters or post-update nodes.
    }
  }
}

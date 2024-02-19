const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;

const units = @import("../units.zig");
const nodepkg = @import("nodes.zig");

/// Transforms a set of PathNode into a new PathNode set that represents a
/// fillable path for a line stroke operation. The path is generated with the
/// supplied thickness.
///
/// The returned node list is owned by the caller and deinit should be
/// called on it.
pub fn transform(
    alloc: mem.Allocator,
    nodes: *std.ArrayList(nodepkg.PathNode),
    thickness: f64,
) !std.ArrayList(nodepkg.PathNode) {
    var result = std.ArrayList(nodepkg.PathNode).init(alloc);
    errdefer result.deinit();

    var it: StrokeNodeIterator = .{
        .alloc = alloc,
        .thickness = thickness,
        .items = nodes,
    };

    while (try it.next()) |x| {
        defer x.deinit();
        try result.appendSlice(x.items);
    }

    return result;
}

/// An iterator that advances a list of PathNodes by each fillable line.
const StrokeNodeIterator = struct {
    alloc: mem.Allocator,
    thickness: f64,
    items: *const std.ArrayList(nodepkg.PathNode),
    index: usize = 0,

    pub fn next(it: *StrokeNodeIterator) !?std.ArrayList(nodepkg.PathNode) {
        debug.assert(it.index <= it.items.items.len);
        if (it.index >= it.items.items.len) return null;

        // Our line joins.
        //
        // TODO: Maybe group these for symmetry with things like len and other
        // operations that make the assumption (correctly) that both of these
        // will always be of equal length.
        var outer_joins = std.ArrayList(units.Point).init(it.alloc);
        var inner_joins = std.ArrayList(units.Point).init(it.alloc);
        defer outer_joins.deinit();
        defer inner_joins.deinit();

        // Our point state for the transformer. We need at least 3 points to
        // calculate a join, so we keep track of 2 points here (last point, current
        // point) and combine that with the point being processed. The initial
        // point stores the point of our last move_to.
        var initial_point_: ?units.Point = null;
        var first_line_point_: ?units.Point = null;
        var current_point_: ?units.Point = null;
        var last_point_: ?units.Point = null;

        while (it.index < it.items.items.len) : (it.index += 1) {
            switch (it.items.items[it.index]) {
                .move_to => |node| {
                    // move_to with initial point means we're at the end of the
                    // current line
                    if (initial_point_ != null) break;

                    initial_point_ = node.point;
                    current_point_ = node.point;
                },
                .curve_to => {
                    if (initial_point_ != null) {
                        // TODO: handle curve_to
                    } else unreachable; // curve_to should never be called internally without move_to
                },
                .line_to => |node| {
                    if (initial_point_ != null) {
                        if (current_point_) |current_point| {
                            if (last_point_) |last_point| {
                                // Join the lines last -> current -> node, with
                                // the join points representing the points
                                // around current.
                                const current_joins = join(
                                    last_point,
                                    current_point,
                                    node.point,
                                    it.thickness,
                                );
                                try outer_joins.append(current_joins[0]);
                                try inner_joins.append(current_joins[1]);
                            }
                        } else unreachable; // move_to always sets both initial and current points
                        if (first_line_point_ == null) {
                            first_line_point_ = node.point;
                        }
                        last_point_ = current_point_;
                        current_point_ = node.point;
                    } else unreachable; // line_to should never be called internally without move_to
                },
                .close_path => {
                    if (initial_point_ != null) {
                        // TODO: handle close_path
                    } else unreachable; // close_path should never be called internally without move_to
                },
            }
        }

        if (initial_point_) |initial_point| {
            if (current_point_) |current_point| {
                if (initial_point.equal(current_point) and outer_joins.items.len == 0) {
                    // This means that the line was never effectively moved to
                    // another point, so we should not draw anything.
                    return std.ArrayList(nodepkg.PathNode).init(it.alloc);
                }
                if (first_line_point_) |first_line_point| {
                    if (last_point_) |last_point| {
                        // Initialize the result to the size of our joins, plus 5 nodes for:
                        //
                        // * Initial move_to (outer cap point)
                        // * End cap line_to nodes
                        // * Start inner cap point
                        // * Final close_path node
                        //
                        // This will possibly change when we add more cap modes (round
                        // caps particularly may keep us from being able to
                        // pre-determine capacity).
                        var result = try std.ArrayList(nodepkg.PathNode).initCapacity(
                            it.alloc,
                            outer_joins.items.len + inner_joins.items.len + 5,
                        );
                        errdefer result.deinit();

                        // What we do to add points depends on whether or not we have joins.
                        //
                        // Note that we always expect the joins to be
                        // symmetrical, so we can just check one (here, the
                        // outer).
                        debug.assert(outer_joins.items.len == inner_joins.items.len);
                        if (outer_joins.items.len > 0) {
                            const cap_points_start = Face.init(
                                initial_point,
                                first_line_point,
                                it.thickness,
                            );
                            const cap_points_end = Face.init(
                                last_point,
                                current_point,
                                it.thickness,
                            );
                            try result.append(.{ .move_to = .{ .point = cap_points_start.p0_ccw() } });
                            for (outer_joins.items) |j| try result.append(.{ .line_to = .{ .point = j } });
                            try result.append(.{ .line_to = .{ .point = cap_points_end.p1_ccw() } });
                            try result.append(.{ .line_to = .{ .point = cap_points_end.p1_cw() } });
                            {
                                var i: i32 = @intCast(inner_joins.items.len - 1);
                                while (i >= 0) : (i -= 1) {
                                    try result.append(
                                        .{ .line_to = .{ .point = inner_joins.items[@intCast(i)] } },
                                    );
                                }
                            }
                            try result.append(.{ .line_to = .{ .point = cap_points_start.p0_cw() } });
                            try result.append(.{ .close_path = .{} });
                        } else {
                            // We can just fast-path here to drawing the single
                            // line off of our start line caps.
                            const cap_points = Face.init(initial_point, current_point, it.thickness);
                            try result.append(.{ .move_to = .{ .point = cap_points.p0_ccw() } });
                            try result.append(.{ .line_to = .{ .point = cap_points.p1_ccw() } });
                            try result.append(.{ .line_to = .{ .point = cap_points.p1_cw() } });
                            try result.append(.{ .line_to = .{ .point = cap_points.p0_cw() } });
                            try result.append(.{ .close_path = .{} });
                        }

                        // Done
                        return result;
                    } else unreachable; // line_to always sets last_point_
                } else unreachable; // the very first line_to always sets first_line_point_
            } else unreachable; // move_to sets both initial and current points
        }

        // Invalid if we've hit this point (state machine never allows initial
        // point to not be set)
        unreachable;
    }
};

/// Returns points for joining two lines with each other. For point
/// calculations, the lines are treated as pointing in towards each other
/// (e.g., p0 -> p1, p1 <- p2).
fn join(p0: units.Point, p1: units.Point, p2: units.Point, thickness: f64) [2]units.Point {
    // TODO: I'm not 100% about calculating the lines as pointing inward,
    // but it was helpful for me when learning how to understand things
    // like miters, intersections, etc.
    //
    // I might eventually switch this to terminology that works like Cairo
    // where faces in joins seem to have an incoming -> outgoing nomenclature
    // (e.g. p0 -> p1, p1 -> p2). This would mean we would compare the same
    // side on both faces when calculating inner and outer joins, and you can
    // see the point path following this method during final path generation in
    // the iterator (p0.ccw -> p1.ccw -> p1.cw -> p0.cw).
    //
    // If that happens, we need to update the face intersection logic as well,
    // noting not only the change in sides but also slope direction (another
    // important thing we get from pointing the lines inward for intersection
    // calculation purposes).
    const face_01 = Face.init(p0, p1, thickness);
    const face_12 = Face.init(p2, p1, thickness);
    const outer = face_01.intersect_outer(face_12);
    const inner = face_01.intersect_inner(face_12);

    return .{ outer, inner };
}

const FaceType = enum {
    horizontal,
    vertical,
    diagonal,
};

/// A Face represents a hypothetically-computed polygon edge for a stroked
/// line.
///
/// The face is computed from p0 -> p1 (see init). Interactions, such as
/// intersections, are specifically dictated by the orientation of any two
/// faces in relation to each other, when the faces are treated as lines
/// pointing inwards towards each other (e.g., p0 -> p1, p1 <- p2).
///
/// For each face, its stroked endpoints, denoted by cw (clockwise) and ccw
/// (counter-clockwise) are taken by rotating a point 90 degrees in that
/// direction along the line, starting from p0 (or p1), to half of the line
/// thickness, in the same direction of the line (e.g., p0 -> p1).
const Face = union(FaceType) {
    horizontal: HorizontalFace,
    vertical: VerticalFace,
    diagonal: DiagonalFace,

    /// Computes a Face from two points in the direction of p0 -> p1.
    fn init(p0: units.Point, p1: units.Point, thickness: f64) Face {
        const dy = p1.y - p0.y;
        const dx = p1.x - p0.x;
        const width = thickness / 2;
        if (dy == 0) {
            return .{
                .horizontal = .{
                    .p0 = p0,
                    .p1 = p1,
                    .dx = dx,
                    .offset_y = width,
                    .p0_cw = .{ .x = p0.x, .y = p0.y + math.copysign(width, dx) },
                    .p0_ccw = .{ .x = p0.x, .y = p0.y - math.copysign(width, dx) },
                    .p1_cw = .{ .x = p1.x, .y = p1.y + math.copysign(width, dx) },
                    .p1_ccw = .{ .x = p1.x, .y = p1.y - math.copysign(width, dx) },
                },
            };
        }
        if (dx == 0) {
            return .{
                .vertical = .{
                    .p0 = p0,
                    .p1 = p1,
                    .dy = dy,
                    .offset_x = width,
                    .p0_cw = .{ .x = p0.x - math.copysign(width, dy), .y = p0.y },
                    .p0_ccw = .{ .x = p0.x + math.copysign(width, dy), .y = p0.y },
                    .p1_cw = .{ .x = p1.x - math.copysign(width, dy), .y = p1.y },
                    .p1_ccw = .{ .x = p1.x + math.copysign(width, dy), .y = p1.y },
                },
            };
        }

        const theta = math.atan2(f64, dy, dx);
        const offset_x = thickness / 2 * @sin(theta);
        const offset_y = thickness / 2 * @cos(theta);
        return .{
            .diagonal = .{
                .p0 = p0,
                .p1 = p1,
                .dx = dx,
                .dy = dy,
                .slope = dy / dx,
                .offset_x = offset_x,
                .offset_y = offset_y,
                .p0_cw = .{ .x = p0.x - offset_x, .y = p0.y + offset_y },
                .p0_ccw = .{ .x = p0.x + offset_x, .y = p0.y - offset_y },
                .p1_cw = .{ .x = p1.x - offset_x, .y = p1.y + offset_y },
                .p1_ccw = .{ .x = p1.x + offset_x, .y = p1.y - offset_y },
            },
        };
    }

    fn p0_cw(self: Face) units.Point {
        return switch (self) {
            .horizontal => |f| f.p0_cw,
            .vertical => |f| f.p0_cw,
            .diagonal => |f| f.p0_cw,
        };
    }

    fn p0_ccw(self: Face) units.Point {
        return switch (self) {
            .horizontal => |f| f.p0_ccw,
            .vertical => |f| f.p0_ccw,
            .diagonal => |f| f.p0_ccw,
        };
    }

    fn p1_cw(self: Face) units.Point {
        return switch (self) {
            .horizontal => |f| f.p1_cw,
            .vertical => |f| f.p1_cw,
            .diagonal => |f| f.p1_cw,
        };
    }

    fn p1_ccw(self: Face) units.Point {
        return switch (self) {
            .horizontal => |f| f.p1_ccw,
            .vertical => |f| f.p1_ccw,
            .diagonal => |f| f.p1_ccw,
        };
    }

    /// Returns the intersection of the outer edges of this face and another.
    fn intersect_outer(self: Face, other: Face) units.Point {
        return switch (self) {
            .horizontal => |f| f.intersect_outer(other),
            .vertical => |f| f.intersect_outer(other),
            .diagonal => |f| f.intersect_outer(other),
        };
    }

    /// Returns the intersection of the inner edges of this face and another.
    fn intersect_inner(self: Face, other: Face) units.Point {
        return switch (self) {
            .horizontal => |f| f.intersect_inner(other),
            .vertical => |f| f.intersect_inner(other),
            .diagonal => |f| f.intersect_inner(other),
        };
    }
};

const HorizontalFace = struct {
    p0: units.Point,
    p1: units.Point,
    dx: f64,
    offset_y: f64,
    p0_cw: units.Point,
    p0_ccw: units.Point,
    p1_cw: units.Point,
    p1_ccw: units.Point,

    fn intersect_outer(self: HorizontalFace, other: Face) units.Point {
        switch (other) {
            .horizontal => {
                // We can just return our end-point outer
                return self.p1_ccw;
            },
            .vertical => |vert| {
                // Take the x/y intersection of our outer points.
                return .{
                    .x = vert.p0_cw.x,
                    .y = self.p0_ccw.y,
                };
            },
            .diagonal => |diag| {
                // Take the x-intercept with the origin being the horizontal
                // line outer point.
                return .{
                    .x = diag.p0_cw.x - ((diag.p0_cw.y - self.p0_ccw.y) / diag.slope),
                    .y = self.p0_ccw.y,
                };
            },
        }
    }
    fn intersect_inner(self: HorizontalFace, other: Face) units.Point {
        switch (other) {
            .horizontal => {
                // We can just return our end-point inner
                return self.p1_cw;
            },
            .vertical => |vert| {
                // Take the x/y intersection of our inner points.
                return .{
                    .x = vert.p0_ccw.x,
                    .y = self.p0_cw.y,
                };
            },
            .diagonal => |diag| {
                // Take the x-intercept with the origin being the horizontal
                // line inner point.
                return .{
                    .x = diag.p0_ccw.x - ((diag.p0_ccw.y - self.p0_cw.y) / diag.slope),
                    .y = self.p0_cw.y,
                };
            },
        }
    }
};

const VerticalFace = struct {
    p0: units.Point,
    p1: units.Point,
    dy: f64,
    offset_x: f64,
    p0_cw: units.Point,
    p0_ccw: units.Point,
    p1_cw: units.Point,
    p1_ccw: units.Point,

    fn intersect_outer(self: VerticalFace, other: Face) units.Point {
        switch (other) {
            .horizontal => |horiz| {
                // Take the x/y intersection of our outer points.
                return .{
                    .x = self.p0_ccw.x,
                    .y = horiz.p0_cw.y,
                };
            },
            .vertical => {
                // We can just return our end-point outer
                return self.p1_ccw;
            },
            .diagonal => |diag| {
                // Take the y-intercept with the origin being the vertical
                // line outer point.
                return .{
                    .x = self.p0_ccw.x,
                    .y = diag.p0_cw.y - (diag.slope * (diag.p0_cw.x - self.p0_ccw.x)),
                };
            },
        }
    }

    fn intersect_inner(self: VerticalFace, other: Face) units.Point {
        switch (other) {
            .horizontal => |horiz| {
                // Take the x/y intersection of our inner points.
                return .{
                    .x = self.p0_cw.x,
                    .y = horiz.p0_ccw.y,
                };
            },
            .vertical => {
                // We can just return our end-point inner
                return self.p1_cw;
            },
            .diagonal => |diag| {
                // Take the y-intercept with the origin being the vertical
                // line inner point.
                return .{
                    .x = self.p0_cw.x,
                    .y = diag.p0_ccw.y - (diag.slope * (diag.p0_ccw.x - self.p0_cw.x)),
                };
            },
        }
    }
};

const DiagonalFace = struct {
    p0: units.Point,
    p1: units.Point,
    dx: f64,
    dy: f64,
    slope: f64,
    offset_x: f64,
    offset_y: f64,
    p0_cw: units.Point,
    p0_ccw: units.Point,
    p1_cw: units.Point,
    p1_ccw: units.Point,

    fn intersect_outer(self: DiagonalFace, other: Face) units.Point {
        switch (other) {
            .horizontal => |horiz| {
                // Take the x-intercept with the origin being the horizontal
                // line outer point.
                return .{
                    .x = self.p0_ccw.x + ((horiz.p0_cw.y - self.p0_ccw.y) / self.slope),
                    .y = horiz.p0_cw.y,
                };
            },
            .vertical => |vert| {
                // Take the y-intercept with the origin being the vertical
                // line outer point.
                return .{
                    .x = vert.p0_cw.x,
                    .y = self.p0_ccw.y + (self.slope * (vert.p0_cw.x - self.p0_ccw.x)),
                };
            },
            .diagonal => |diag| {
                return intersect(self.p0_ccw, diag.p0_cw, self.slope, diag.slope);
            },
        }
    }

    fn intersect_inner(self: DiagonalFace, other: Face) units.Point {
        switch (other) {
            .horizontal => |horiz| {
                // Take the x-intercept with the origin being the horizontal
                // line outer point.
                return .{
                    .x = self.p0_cw.x + ((horiz.p0_ccw.y - self.p0_cw.y) / self.slope),
                    .y = horiz.p0_ccw.y,
                };
            },
            .vertical => |vert| {
                // Take the y-intercept with the origin being the vertical
                // line outer point.
                return .{
                    .x = vert.p0_ccw.x,
                    .y = self.p0_cw.y + (self.slope * (vert.p0_ccw.x - self.p0_cw.x)),
                };
            },
            .diagonal => |diag| {
                return intersect(self.p0_cw, diag.p0_ccw, self.slope, diag.slope);
            },
        }
    }
};

fn intersect(p0: units.Point, p1: units.Point, m0: f64, m1: f64) units.Point {
    // We do line-line intersection, based on the following equation:
    //
    // self.dy/self.dx + self.p0.y == other.dy/other.dx + other.p0.y
    //
    // This is line-line intercept when both y positions are normalized at
    // their y-intercepts (e.g. x=0).
    //
    // We take p0 at self as our reference origin, so normalize our other
    // point based on the difference between the two points in x-position.
    //
    // Source: Line-line intersection, Wikipedia contributors:
    // https://en.wikipedia.org/w/index.php?title=Line%E2%80%93line_intersection&oldid=1198068392.
    // See link for further details.
    const other_y_intercept = p1.y - (m1 * (p1.x - p0.x));

    // We can now compute our intersections. Note that we have to add the x of
    // p0 as an offset, as we have assumed this is the origin.
    const intersect_x = (other_y_intercept - p0.y) / (m0 - m1) + p0.x;
    const intersect_y = m0 * ((other_y_intercept - p0.y) / (m0 - m1)) + p0.y;
    return .{
        .x = intersect_x,
        .y = intersect_y,
    };
}

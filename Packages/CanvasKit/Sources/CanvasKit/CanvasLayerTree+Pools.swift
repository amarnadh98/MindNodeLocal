import CoreGraphics
import Foundation
import QuartzCore

/// Fade-out lifecycle, the layer pools and the 120 ms zoom-settle pass
/// of the virtualized layer tree (SPEC §11.4) — split out of
/// `CanvasLayerTree` to keep the class body reviewable.
extension CanvasLayerTree {
    // MARK: disappearing layers

    func startNodeDisappear(_ layer: NodeVisualLayer, camera: Camera) {
        layer.opacity = 0
        layer.transform = Self.nodeTransform(for: camera)
        dyingNodes[layer.nodeID] = layer
        for (index, animation) in RelayoutAnimator.disappearAnimations(camera: camera)
            .enumerated()
        {
            layer.add(animation, forKey: "disappear-\(index)")
        }
    }

    func startBranchDisappear(_ layer: BranchVisualLayer) {
        layer.opacity = 0
        dyingBranches.append(layer)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = RelayoutAnimator.disappearDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(fade, forKey: "disappear-opacity")
    }

    func finishDyingNode(_ id: String) {
        guard let layer = dyingNodes.removeValue(forKey: id) else { return }
        recycleNodeLayer(layer)
    }

    /// Sweeps fade layers whose 160 ms window has closed. Headless
    /// (no CA clock) this is what actually recycles them.
    func scheduleDyingSweep() {
        dyingSweepTask?.cancel()
        dyingSweepTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dyingSweepDelay)
            guard !Task.isCancelled, let self else { return }
            for id in Array(self.dyingNodes.keys) {
                self.finishDyingNode(id)
            }
            for layer in self.dyingBranches {
                self.recycleBranchLayer(layer)
            }
            self.dyingBranches.removeAll()
        }
    }

    // MARK: pools

    func dequeueNodeLayer(id: String) -> NodeVisualLayer {
        guard let layer = nodePool.popLast() else {
            allocatedNodeLayers += 1
            return NodeVisualLayer(nodeID: id)
        }
        pooledNodeLayerReuses += 1
        layer.reset(for: id)
        return layer
    }

    func recycleNodeLayer(_ layer: NodeVisualLayer) {
        layer.removeFromSuperlayer()
        layer.removeAllAnimations()
        layer.contents = nil
        layer.rasterKey = nil
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        if nodePool.count < Self.nodePoolCap {
            nodePool.append(layer)
        }
    }

    func dequeueBranchLayer(key: BranchKey) -> BranchVisualLayer {
        allocatedBranchLayers += 1
        guard let layer = branchPool.popLast() else { return BranchVisualLayer(key: key) }
        layer.reset(for: key)
        return layer
    }

    func recycleBranchLayer(_ layer: BranchVisualLayer) {
        layer.removeFromSuperlayer()
        layer.removeAllAnimations()
        layer.path = nil
        layer.branch = nil
        layer.opacity = 1
        layer.fillColor = nil
        layer.strokeColor = nil
        if branchPool.count < Self.branchPoolCap {
            branchPool.append(layer)
        }
    }

    // MARK: zoom settle

    func scheduleSettleIfNeeded(camera: Camera, backingScale: CGFloat) {
        guard abs(camera.scale - lastScale) > 0.0001 else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.zoomSettleDelay)
            guard !Task.isCancelled, let self else { return }
            self.rerasterizeVisible(camera: camera, backingScale: backingScale)
        }
    }

    func rerasterNode(_ id: String?, camera: Camera, backingScale: CGFloat) {
        guard let id, let layer = nodeLayers[id], let node = scene?.nodes[id] else { return }
        configureContents(layer, node: node, camera: camera, backingScale: backingScale)
    }
}

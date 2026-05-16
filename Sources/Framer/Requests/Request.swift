public enum Request: Equatable, Sendable {
    case createWindow(CreateWindow)
    case changeWindowAttributes(ChangeWindowAttributes)
    case getWindowAttributes(GetWindowAttributes)
    case destroyWindow(DestroyWindow)
    case destroySubwindows(DestroySubwindows)
    case reparentWindow(ReparentWindow)
    case mapWindow(MapWindow)
    case mapSubwindows(MapSubwindows)
    case unmapWindow(UnmapWindow)
    case unmapSubwindows(UnmapSubwindows)
    case configureWindow(ConfigureWindow)
    case getGeometry(GetGeometry)
    case queryTree(QueryTree)
    case internAtom(InternAtom)
    case getAtomName(GetAtomName)
    case changeProperty(ChangeProperty)
    case deleteProperty(DeleteProperty)
    case getProperty(GetProperty)
    case setSelectionOwner(SetSelectionOwner)
    case getSelectionOwner(GetSelectionOwner)
    case convertSelection(ConvertSelection)
    case sendEvent(SendEvent)
    case grabPointer(GrabPointer)
    case ungrabPointer(UngrabPointer)
    case grabButton(GrabButton)
    case changeActivePointerGrab(ChangeActivePointerGrab)
    case grabKeyboard(GrabKeyboard)
    case ungrabKeyboard(UngrabKeyboard)
    case grabKey(GrabKey)
    case allowEvents(AllowEvents)
    case grabServer(GrabServer)
    case ungrabServer(UngrabServer)
    case queryPointer(QueryPointer)
    case translateCoordinates(TranslateCoordinates)
    case warpPointer(WarpPointer)
    case setInputFocus(SetInputFocus)
    case getInputFocus(GetInputFocus)
    case queryKeymap(QueryKeymap)
    case openFont(OpenFont)
    case closeFont(CloseFont)
    case queryFont(QueryFont)
    case listFonts(ListFonts)
    case createPixmap(CreatePixmap)
    case freePixmap(FreePixmap)
    case createGC(CreateGC)
    case freeGC(FreeGC)
    case setDashes(SetDashes)
    case setClipRectangles(SetClipRectangles)
    case clearArea(ClearArea)
    case copyArea(CopyArea)
    case changeGC(ChangeGC)
    case polyLine(PolyLine)
    case polySegment(PolySegment)
    case polyArc(PolyArc)
    case fillPoly(FillPoly)
    case polyRectangle(PolyRectangle)
    case polyFillRectangle(PolyFillRectangle)
    case polyFillArc(PolyFillArc)
    case putImage(PutImage)
    case polyText8(PolyText8)
    case imageText8(ImageText8)
    case allocColor(AllocColor)
    case allocNamedColor(AllocNamedColor)
    case queryColors(QueryColors)
    case lookupColor(LookupColor)
    case queryBestSize(QueryBestSize)
    case queryExtension(QueryExtension)
    case bell(Bell)
    case createGlyphCursor(CreateGlyphCursor)
    case freeCursor(FreeCursor)
    case recolorCursor(RecolorCursor)
    case listExtensions(ListExtensions)
    case getKeyboardMapping(GetKeyboardMapping)
    case getModifierMapping(GetModifierMapping)
    case getPointerMapping(GetPointerMapping)
    case ungrabButton(UngrabButton)
    case ungrabKey(UngrabKey)
    case getMotionEvents(GetMotionEvents)
    case allocColorCells(AllocColorCells)
    case setCloseDownMode(SetCloseDownMode)
    case killClient(KillClient)
    case noOperation(NoOperation)
    case createColormap(CreateColormap)
    case freeColormap(FreeColormap)
    case copyColormapAndFree(CopyColormapAndFree)
    case installColormap(InstallColormap)
    case uninstallColormap(UninstallColormap)
    case listInstalledColormaps(ListInstalledColormaps)
    case allocColorPlanes(AllocColorPlanes)
    case freeColors(FreeColors)
    case storeColors(StoreColors)
    case storeNamedColor(StoreNamedColor)
    case circulateWindow(CirculateWindow)
    case queryTextExtents(QueryTextExtents)
    case polyPoint(PolyPoint)
    // Carries the full request bytes including the 4-byte header. Encode is a
    // pass-through and ignores the byteOrder argument since the bytes are already
    // in their original byte order.
    case unknown(opcode: UInt8, bytes: [UInt8])

    public func encode(byteOrder: ByteOrder) -> [UInt8] {
        switch self {
        case .createWindow(let r):              return r.encode(byteOrder: byteOrder)
        case .changeWindowAttributes(let r):    return r.encode(byteOrder: byteOrder)
        case .getWindowAttributes(let r):       return r.encode(byteOrder: byteOrder)
        case .destroyWindow(let r):             return r.encode(byteOrder: byteOrder)
        case .destroySubwindows(let r):         return r.encode(byteOrder: byteOrder)
        case .reparentWindow(let r):            return r.encode(byteOrder: byteOrder)
        case .mapWindow(let r):                 return r.encode(byteOrder: byteOrder)
        case .mapSubwindows(let r):             return r.encode(byteOrder: byteOrder)
        case .unmapWindow(let r):               return r.encode(byteOrder: byteOrder)
        case .unmapSubwindows(let r):           return r.encode(byteOrder: byteOrder)
        case .configureWindow(let r):           return r.encode(byteOrder: byteOrder)
        case .getGeometry(let r):               return r.encode(byteOrder: byteOrder)
        case .queryTree(let r):                 return r.encode(byteOrder: byteOrder)
        case .internAtom(let r):                return r.encode(byteOrder: byteOrder)
        case .getAtomName(let r):               return r.encode(byteOrder: byteOrder)
        case .changeProperty(let r):            return r.encode(byteOrder: byteOrder)
        case .deleteProperty(let r):            return r.encode(byteOrder: byteOrder)
        case .getProperty(let r):               return r.encode(byteOrder: byteOrder)
        case .setSelectionOwner(let r):         return r.encode(byteOrder: byteOrder)
        case .getSelectionOwner(let r):         return r.encode(byteOrder: byteOrder)
        case .convertSelection(let r):          return r.encode(byteOrder: byteOrder)
        case .sendEvent(let r):                 return r.encode(byteOrder: byteOrder)
        case .grabPointer(let r):               return r.encode(byteOrder: byteOrder)
        case .ungrabPointer(let r):             return r.encode(byteOrder: byteOrder)
        case .grabButton(let r):                return r.encode(byteOrder: byteOrder)
        case .changeActivePointerGrab(let r):   return r.encode(byteOrder: byteOrder)
        case .grabKeyboard(let r):              return r.encode(byteOrder: byteOrder)
        case .ungrabKeyboard(let r):            return r.encode(byteOrder: byteOrder)
        case .grabKey(let r):                   return r.encode(byteOrder: byteOrder)
        case .allowEvents(let r):               return r.encode(byteOrder: byteOrder)
        case .grabServer(let r):                return r.encode(byteOrder: byteOrder)
        case .ungrabServer(let r):              return r.encode(byteOrder: byteOrder)
        case .queryPointer(let r):              return r.encode(byteOrder: byteOrder)
        case .translateCoordinates(let r):      return r.encode(byteOrder: byteOrder)
        case .warpPointer(let r):               return r.encode(byteOrder: byteOrder)
        case .setInputFocus(let r):             return r.encode(byteOrder: byteOrder)
        case .getInputFocus(let r):             return r.encode(byteOrder: byteOrder)
        case .queryKeymap(let r):               return r.encode(byteOrder: byteOrder)
        case .openFont(let r):                  return r.encode(byteOrder: byteOrder)
        case .closeFont(let r):                 return r.encode(byteOrder: byteOrder)
        case .queryFont(let r):                 return r.encode(byteOrder: byteOrder)
        case .listFonts(let r):                 return r.encode(byteOrder: byteOrder)
        case .createPixmap(let r):              return r.encode(byteOrder: byteOrder)
        case .freePixmap(let r):                return r.encode(byteOrder: byteOrder)
        case .createGC(let r):                  return r.encode(byteOrder: byteOrder)
        case .freeGC(let r):                    return r.encode(byteOrder: byteOrder)
        case .setDashes(let r):                 return r.encode(byteOrder: byteOrder)
        case .setClipRectangles(let r):         return r.encode(byteOrder: byteOrder)
        case .clearArea(let r):                 return r.encode(byteOrder: byteOrder)
        case .copyArea(let r):                  return r.encode(byteOrder: byteOrder)
        case .changeGC(let r):                  return r.encode(byteOrder: byteOrder)
        case .polyLine(let r):                  return r.encode(byteOrder: byteOrder)
        case .polySegment(let r):               return r.encode(byteOrder: byteOrder)
        case .polyArc(let r):                   return r.encode(byteOrder: byteOrder)
        case .fillPoly(let r):                  return r.encode(byteOrder: byteOrder)
        case .polyRectangle(let r):             return r.encode(byteOrder: byteOrder)
        case .polyFillRectangle(let r):         return r.encode(byteOrder: byteOrder)
        case .polyFillArc(let r):               return r.encode(byteOrder: byteOrder)
        case .putImage(let r):                  return r.encode(byteOrder: byteOrder)
        case .polyText8(let r):                 return r.encode(byteOrder: byteOrder)
        case .imageText8(let r):                return r.encode(byteOrder: byteOrder)
        case .allocColor(let r):                return r.encode(byteOrder: byteOrder)
        case .allocNamedColor(let r):           return r.encode(byteOrder: byteOrder)
        case .queryColors(let r):               return r.encode(byteOrder: byteOrder)
        case .lookupColor(let r):               return r.encode(byteOrder: byteOrder)
        case .queryBestSize(let r):             return r.encode(byteOrder: byteOrder)
        case .queryExtension(let r):            return r.encode(byteOrder: byteOrder)
        case .bell(let r):                      return r.encode(byteOrder: byteOrder)
        case .createGlyphCursor(let r):         return r.encode(byteOrder: byteOrder)
        case .freeCursor(let r):                return r.encode(byteOrder: byteOrder)
        case .recolorCursor(let r):             return r.encode(byteOrder: byteOrder)
        case .listExtensions(let r):            return r.encode(byteOrder: byteOrder)
        case .getKeyboardMapping(let r):        return r.encode(byteOrder: byteOrder)
        case .getModifierMapping(let r):        return r.encode(byteOrder: byteOrder)
        case .getPointerMapping(let r):         return r.encode(byteOrder: byteOrder)
        case .ungrabButton(let r):              return r.encode(byteOrder: byteOrder)
        case .ungrabKey(let r):                 return r.encode(byteOrder: byteOrder)
        case .getMotionEvents(let r):           return r.encode(byteOrder: byteOrder)
        case .allocColorCells(let r):           return r.encode(byteOrder: byteOrder)
        case .setCloseDownMode(let r):          return r.encode(byteOrder: byteOrder)
        case .killClient(let r):                return r.encode(byteOrder: byteOrder)
        case .noOperation(let r):               return r.encode(byteOrder: byteOrder)
        case .createColormap(let r):            return r.encode(byteOrder: byteOrder)
        case .freeColormap(let r):              return r.encode(byteOrder: byteOrder)
        case .copyColormapAndFree(let r):       return r.encode(byteOrder: byteOrder)
        case .installColormap(let r):           return r.encode(byteOrder: byteOrder)
        case .uninstallColormap(let r):         return r.encode(byteOrder: byteOrder)
        case .listInstalledColormaps(let r):    return r.encode(byteOrder: byteOrder)
        case .allocColorPlanes(let r):          return r.encode(byteOrder: byteOrder)
        case .freeColors(let r):                return r.encode(byteOrder: byteOrder)
        case .storeColors(let r):               return r.encode(byteOrder: byteOrder)
        case .storeNamedColor(let r):           return r.encode(byteOrder: byteOrder)
        case .circulateWindow(let r):           return r.encode(byteOrder: byteOrder)
        case .queryTextExtents(let r):          return r.encode(byteOrder: byteOrder)
        case .polyPoint(let r):                 return r.encode(byteOrder: byteOrder)
        case .unknown(_, let bytes):            return bytes
        }
    }

    public static func decode(from bytes: [UInt8], byteOrder: ByteOrder) throws -> Request {
        guard bytes.count >= 4 else {
            throw FramerError.truncated(needed: 4, available: bytes.count)
        }
        let opcode = bytes[0]
        let lenIn4: UInt16
        switch byteOrder {
        case .lsbFirst: lenIn4 = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        case .msbFirst: lenIn4 = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        }
        let expected = Int(lenIn4) * 4
        guard bytes.count >= expected else {
            throw FramerError.truncated(needed: expected, available: bytes.count)
        }

        switch opcode {
        case CreateWindow.opcode:
            return .createWindow(try CreateWindow.decode(from: bytes, byteOrder: byteOrder))
        case ChangeWindowAttributes.opcode:
            return .changeWindowAttributes(try ChangeWindowAttributes.decode(from: bytes, byteOrder: byteOrder))
        case GetWindowAttributes.opcode:
            return .getWindowAttributes(try GetWindowAttributes.decode(from: bytes, byteOrder: byteOrder))
        case DestroyWindow.opcode:
            return .destroyWindow(try DestroyWindow.decode(from: bytes, byteOrder: byteOrder))
        case DestroySubwindows.opcode:
            return .destroySubwindows(try DestroySubwindows.decode(from: bytes, byteOrder: byteOrder))
        case ReparentWindow.opcode:
            return .reparentWindow(try ReparentWindow.decode(from: bytes, byteOrder: byteOrder))
        case MapWindow.opcode:
            return .mapWindow(try MapWindow.decode(from: bytes, byteOrder: byteOrder))
        case MapSubwindows.opcode:
            return .mapSubwindows(try MapSubwindows.decode(from: bytes, byteOrder: byteOrder))
        case UnmapWindow.opcode:
            return .unmapWindow(try UnmapWindow.decode(from: bytes, byteOrder: byteOrder))
        case UnmapSubwindows.opcode:
            return .unmapSubwindows(try UnmapSubwindows.decode(from: bytes, byteOrder: byteOrder))
        case ConfigureWindow.opcode:
            return .configureWindow(try ConfigureWindow.decode(from: bytes, byteOrder: byteOrder))
        case GetGeometry.opcode:
            return .getGeometry(try GetGeometry.decode(from: bytes, byteOrder: byteOrder))
        case QueryTree.opcode:
            return .queryTree(try QueryTree.decode(from: bytes, byteOrder: byteOrder))
        case InternAtom.opcode:
            return .internAtom(try InternAtom.decode(from: bytes, byteOrder: byteOrder))
        case GetAtomName.opcode:
            return .getAtomName(try GetAtomName.decode(from: bytes, byteOrder: byteOrder))
        case ChangeProperty.opcode:
            return .changeProperty(try ChangeProperty.decode(from: bytes, byteOrder: byteOrder))
        case DeleteProperty.opcode:
            return .deleteProperty(try DeleteProperty.decode(from: bytes, byteOrder: byteOrder))
        case GetProperty.opcode:
            return .getProperty(try GetProperty.decode(from: bytes, byteOrder: byteOrder))
        case SetSelectionOwner.opcode:
            return .setSelectionOwner(try SetSelectionOwner.decode(from: bytes, byteOrder: byteOrder))
        case GetSelectionOwner.opcode:
            return .getSelectionOwner(try GetSelectionOwner.decode(from: bytes, byteOrder: byteOrder))
        case ConvertSelection.opcode:
            return .convertSelection(try ConvertSelection.decode(from: bytes, byteOrder: byteOrder))
        case SendEvent.opcode:
            return .sendEvent(try SendEvent.decode(from: bytes, byteOrder: byteOrder))
        case GrabPointer.opcode:
            return .grabPointer(try GrabPointer.decode(from: bytes, byteOrder: byteOrder))
        case UngrabPointer.opcode:
            return .ungrabPointer(try UngrabPointer.decode(from: bytes, byteOrder: byteOrder))
        case GrabButton.opcode:
            return .grabButton(try GrabButton.decode(from: bytes, byteOrder: byteOrder))
        case ChangeActivePointerGrab.opcode:
            return .changeActivePointerGrab(try ChangeActivePointerGrab.decode(from: bytes, byteOrder: byteOrder))
        case GrabKeyboard.opcode:
            return .grabKeyboard(try GrabKeyboard.decode(from: bytes, byteOrder: byteOrder))
        case UngrabKeyboard.opcode:
            return .ungrabKeyboard(try UngrabKeyboard.decode(from: bytes, byteOrder: byteOrder))
        case GrabKey.opcode:
            return .grabKey(try GrabKey.decode(from: bytes, byteOrder: byteOrder))
        case AllowEvents.opcode:
            return .allowEvents(try AllowEvents.decode(from: bytes, byteOrder: byteOrder))
        case GrabServer.opcode:
            return .grabServer(try GrabServer.decode(from: bytes, byteOrder: byteOrder))
        case UngrabServer.opcode:
            return .ungrabServer(try UngrabServer.decode(from: bytes, byteOrder: byteOrder))
        case QueryPointer.opcode:
            return .queryPointer(try QueryPointer.decode(from: bytes, byteOrder: byteOrder))
        case TranslateCoordinates.opcode:
            return .translateCoordinates(try TranslateCoordinates.decode(from: bytes, byteOrder: byteOrder))
        case WarpPointer.opcode:
            return .warpPointer(try WarpPointer.decode(from: bytes, byteOrder: byteOrder))
        case SetInputFocus.opcode:
            return .setInputFocus(try SetInputFocus.decode(from: bytes, byteOrder: byteOrder))
        case GetInputFocus.opcode:
            return .getInputFocus(try GetInputFocus.decode(from: bytes, byteOrder: byteOrder))
        case QueryKeymap.opcode:
            return .queryKeymap(try QueryKeymap.decode(from: bytes, byteOrder: byteOrder))
        case OpenFont.opcode:
            return .openFont(try OpenFont.decode(from: bytes, byteOrder: byteOrder))
        case CloseFont.opcode:
            return .closeFont(try CloseFont.decode(from: bytes, byteOrder: byteOrder))
        case QueryFont.opcode:
            return .queryFont(try QueryFont.decode(from: bytes, byteOrder: byteOrder))
        case ListFonts.opcode:
            return .listFonts(try ListFonts.decode(from: bytes, byteOrder: byteOrder))
        case CreatePixmap.opcode:
            return .createPixmap(try CreatePixmap.decode(from: bytes, byteOrder: byteOrder))
        case FreePixmap.opcode:
            return .freePixmap(try FreePixmap.decode(from: bytes, byteOrder: byteOrder))
        case CreateGC.opcode:
            return .createGC(try CreateGC.decode(from: bytes, byteOrder: byteOrder))
        case FreeGC.opcode:
            return .freeGC(try FreeGC.decode(from: bytes, byteOrder: byteOrder))
        case SetDashes.opcode:
            return .setDashes(try SetDashes.decode(from: bytes, byteOrder: byteOrder))
        case SetClipRectangles.opcode:
            return .setClipRectangles(try SetClipRectangles.decode(from: bytes, byteOrder: byteOrder))
        case ClearArea.opcode:
            return .clearArea(try ClearArea.decode(from: bytes, byteOrder: byteOrder))
        case CopyArea.opcode:
            return .copyArea(try CopyArea.decode(from: bytes, byteOrder: byteOrder))
        case ChangeGC.opcode:
            return .changeGC(try ChangeGC.decode(from: bytes, byteOrder: byteOrder))
        case PolyLine.opcode:
            return .polyLine(try PolyLine.decode(from: bytes, byteOrder: byteOrder))
        case PolySegment.opcode:
            return .polySegment(try PolySegment.decode(from: bytes, byteOrder: byteOrder))
        case PolyArc.opcode:
            return .polyArc(try PolyArc.decode(from: bytes, byteOrder: byteOrder))
        case FillPoly.opcode:
            return .fillPoly(try FillPoly.decode(from: bytes, byteOrder: byteOrder))
        case PolyRectangle.opcode:
            return .polyRectangle(try PolyRectangle.decode(from: bytes, byteOrder: byteOrder))
        case PolyFillRectangle.opcode:
            return .polyFillRectangle(try PolyFillRectangle.decode(from: bytes, byteOrder: byteOrder))
        case PolyFillArc.opcode:
            return .polyFillArc(try PolyFillArc.decode(from: bytes, byteOrder: byteOrder))
        case PutImage.opcode:
            return .putImage(try PutImage.decode(from: bytes, byteOrder: byteOrder))
        case PolyText8.opcode:
            return .polyText8(try PolyText8.decode(from: bytes, byteOrder: byteOrder))
        case ImageText8.opcode:
            return .imageText8(try ImageText8.decode(from: bytes, byteOrder: byteOrder))
        case AllocColor.opcode:
            return .allocColor(try AllocColor.decode(from: bytes, byteOrder: byteOrder))
        case AllocNamedColor.opcode:
            return .allocNamedColor(try AllocNamedColor.decode(from: bytes, byteOrder: byteOrder))
        case QueryColors.opcode:
            return .queryColors(try QueryColors.decode(from: bytes, byteOrder: byteOrder))
        case LookupColor.opcode:
            return .lookupColor(try LookupColor.decode(from: bytes, byteOrder: byteOrder))
        case QueryBestSize.opcode:
            return .queryBestSize(try QueryBestSize.decode(from: bytes, byteOrder: byteOrder))
        case QueryExtension.opcode:
            return .queryExtension(try QueryExtension.decode(from: bytes, byteOrder: byteOrder))
        case Bell.opcode:
            return .bell(try Bell.decode(from: bytes, byteOrder: byteOrder))
        case CreateGlyphCursor.opcode:
            return .createGlyphCursor(try CreateGlyphCursor.decode(from: bytes, byteOrder: byteOrder))
        case FreeCursor.opcode:
            return .freeCursor(try FreeCursor.decode(from: bytes, byteOrder: byteOrder))
        case RecolorCursor.opcode:
            return .recolorCursor(try RecolorCursor.decode(from: bytes, byteOrder: byteOrder))
        case ListExtensions.opcode:
            return .listExtensions(try ListExtensions.decode(from: bytes, byteOrder: byteOrder))
        case GetKeyboardMapping.opcode:
            return .getKeyboardMapping(try GetKeyboardMapping.decode(from: bytes, byteOrder: byteOrder))
        case GetModifierMapping.opcode:
            return .getModifierMapping(try GetModifierMapping.decode(from: bytes, byteOrder: byteOrder))
        case GetPointerMapping.opcode:
            return .getPointerMapping(try GetPointerMapping.decode(from: bytes, byteOrder: byteOrder))
        case UngrabButton.opcode:
            return .ungrabButton(try UngrabButton.decode(from: bytes, byteOrder: byteOrder))
        case UngrabKey.opcode:
            return .ungrabKey(try UngrabKey.decode(from: bytes, byteOrder: byteOrder))
        case GetMotionEvents.opcode:
            return .getMotionEvents(try GetMotionEvents.decode(from: bytes, byteOrder: byteOrder))
        case AllocColorCells.opcode:
            return .allocColorCells(try AllocColorCells.decode(from: bytes, byteOrder: byteOrder))
        case SetCloseDownMode.opcode:
            return .setCloseDownMode(try SetCloseDownMode.decode(from: bytes, byteOrder: byteOrder))
        case KillClient.opcode:
            return .killClient(try KillClient.decode(from: bytes, byteOrder: byteOrder))
        case NoOperation.opcode:
            return .noOperation(try NoOperation.decode(from: bytes, byteOrder: byteOrder))
        case CreateColormap.opcode:
            return .createColormap(try CreateColormap.decode(from: bytes, byteOrder: byteOrder))
        case FreeColormap.opcode:
            return .freeColormap(try FreeColormap.decode(from: bytes, byteOrder: byteOrder))
        case CopyColormapAndFree.opcode:
            return .copyColormapAndFree(try CopyColormapAndFree.decode(from: bytes, byteOrder: byteOrder))
        case InstallColormap.opcode:
            return .installColormap(try InstallColormap.decode(from: bytes, byteOrder: byteOrder))
        case UninstallColormap.opcode:
            return .uninstallColormap(try UninstallColormap.decode(from: bytes, byteOrder: byteOrder))
        case ListInstalledColormaps.opcode:
            return .listInstalledColormaps(try ListInstalledColormaps.decode(from: bytes, byteOrder: byteOrder))
        case AllocColorPlanes.opcode:
            return .allocColorPlanes(try AllocColorPlanes.decode(from: bytes, byteOrder: byteOrder))
        case FreeColors.opcode:
            return .freeColors(try FreeColors.decode(from: bytes, byteOrder: byteOrder))
        case StoreColors.opcode:
            return .storeColors(try StoreColors.decode(from: bytes, byteOrder: byteOrder))
        case StoreNamedColor.opcode:
            return .storeNamedColor(try StoreNamedColor.decode(from: bytes, byteOrder: byteOrder))
        case CirculateWindow.opcode:
            return .circulateWindow(try CirculateWindow.decode(from: bytes, byteOrder: byteOrder))
        case QueryTextExtents.opcode:
            return .queryTextExtents(try QueryTextExtents.decode(from: bytes, byteOrder: byteOrder))
        case PolyPoint.opcode:
            return .polyPoint(try PolyPoint.decode(from: bytes, byteOrder: byteOrder))
        default:
            return .unknown(opcode: opcode, bytes: Array(bytes[0..<expected]))
        }
    }
}

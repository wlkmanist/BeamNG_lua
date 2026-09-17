local sss = scenetree.findObject("ScreenSpaceShadowsPostFx")
if not sss then
  sss = createObject("PostFxScreenSpaceShadows")
  if sss then
    sss:registerObject("ScreenSpaceShadowsPostFx")
  end
end
